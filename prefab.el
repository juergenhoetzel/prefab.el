;;; prefab.el --- Integration for project generation tools -*- lexical-binding: t -*-

;; Author: Laurence Warne
;; Maintainer: Laurence Warne
;; Version: 0.1
;; URL: https://github.com/laurencewarne/prefab.el
;; Package-Requires: ((emacs "27.1") (f "0.2.0") (transient "0.3.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; prefab.el is a tool aiming to provide integration for project generation
;; tools like cookiecutter.  It's main entry point is `prefab', after
;; invocation the steps are:
;; 1) Prompt you for pre-used templates (or you can paste in a new one)
;; 2) Edit the template variables through the transient interface
;; 3) Generate the project

;;; Code:

(require 'python)
(require 'json)
(require 'f)
(require 'transient)
(require 'subr-x)

;;; Custom variables

(defgroup prefab nil
  "Project generation for Emacs."
  :group 'applications)

(defcustom prefab-cookiecutter-template-sources
  (list (format "%s/.cookiecutters" (getenv "HOME")))
  "List of directories to search for cookiecutter templates."
  :group 'prefab
  :type 'directory)

(defcustom prefab-cookiecutter-output-dir
  (format "%s/projects" (getenv "HOME"))
  "Where to output projects generated by cookiecutter."
  :group 'prefab
  :type 'directory)

(defcustom prefab-cookiecutter-replay-dir
  (format "%s/.cookiecutter_replay/" (getenv "HOME"))
  "Where to look for cookiecutter replays."
  :group 'prefab
  :type 'directory)

(defcustom prefab-cookiecutter-python-executable
  python-shell-interpreter
  "The path of the python executable to invoke for cookiecutter code."
  :group 'prefab
  :type 'string)

(defcustom prefab-cookiecutter-get-context-from-replay
  nil
  "If non-nil pre-populate the prefab transient with context from the last run.
Else pre-populate it using the template defaults."
  :group 'prefab
  :type 'boolean)

(defcustom prefab-default-templates
  '(cookiecutter . ("https://github.com/LaurenceWarne/cookiecutter-eldev"))
  "Templates to prompt the user for if completing read would otherwise be empty."
  :group 'prefab
  :type '(alist :key-type symbol :value-type (repeat string)))

;;; Constants

(defconst prefab-version "0.1.0")

;;; Internal variables

(defvar prefab-debug nil)
(defvar prefab-all-keys
  (mapcar #'char-to-string
          (string-to-list
           "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")))

;;; Internal functions

(defun prefab--keys (keywords blacklist)
  "Return an alist of keywords in KEYWORDS to keys not in BLACKLIST."
  (if-let ((kw (car keywords)))
      (let ((key (cl-find-if (lambda (c) (or (not (member c blacklist))
                                             (not (member (upcase c) blacklist))))
                             (mapcar #'char-to-string (string-to-list kw)))))
        (cond ((member key blacklist)
               (cons `(,kw . ,(upcase key))
                     (prefab--keys (cdr keywords) `(,(upcase key) . ,blacklist))))
              (key (cons `(,kw . ,key)
                         (prefab--keys (cdr keywords) `(,key . ,blacklist))))
              (t (if-let ((fallback
                           (cl-find-if (lambda (c) (or (not (member c blacklist))))
                                       prefab-all-keys)))
                     (cons `(,kw . ,fallback)
                           (prefab--keys (cdr keywords) `(,fallback . ,blacklist)))
                   (error "Could not find a complete set of keys")))))))

(defun prefab--cookiecutter-context (template ctx-file &optional original)
  "Return the cookiecutter context for TEMPLATE CTX-FILE.

If ORIGINAL is non-nil, use the original context defaults and not the context
from the last run."
  (let* ((truth (if original "True" "False"))
         (src (format "from cookiecutter.config import get_user_config
from cookiecutter.generate import generate_context
from cookiecutter.replay import load
import json

def default_context():
    return generate_context(
        context_file='%s',
        default_context=config_dict['default_context'],
    )

config_dict = get_user_config()
if %s:
    ctx = default_context()
else:
    try:
        ctx = load(config_dict['replay_dir'], '%s')
    except:
        ctx = default_context()
print(json.dumps(dict(ctx['cookiecutter'])))" ctx-file truth template)))
    (cl-remove-if (lambda (alist-entry)
                    (string-match-p "^_.*" (symbol-name (car alist-entry))))
                  (json-read-from-string
                   (shell-command-to-string
                    (format "%s -c \"%s\""
                            prefab-cookiecutter-python-executable src))))))

(defun prefab--cookiecutter-created-dir (template-dir ctx)
  "Return the created directory implied by TEMPLATE-DIR and CTX (an alist)."
  (print template-dir)
  (let* ((ctx-str (format "{'cookiecutter': %s}"
                          (prefab--alist-to-python-dict ctx)))
         (src (format "from cookiecutter.find import find_template
from cookiecutter.environment import StrictEnvironment
import os.path

ctx = %s
template_dir = find_template('%s')
dirname = os.path.split(template_dir)[1]
envvars = ctx.get('cookiecutter', {}).get('_jinja2_env_vars', {})
env = StrictEnvironment(context=ctx, keep_trailing_newline=True, **envvars)
output_dir = '%s'

name_tmpl = env.from_string(dirname)
rendered_dirname = name_tmpl.render(**ctx)
dir_to_create = os.path.normpath(os.path.join(output_dir, rendered_dirname))
print(dir_to_create, end='')"
                      ctx-str template-dir prefab-cookiecutter-output-dir)))
    (shell-command-to-string
     (format "%s -c \"%s\"" prefab-cookiecutter-python-executable src))))

(defun prefab--cookiecutter-download-template (template)
  "Download TEMPLATE and return the template directory."
  (let ((src (format "from cookiecutter.config import get_user_config
from cookiecutter.repository import determine_repo_dir

config_dict = get_user_config()
repo_dir, cleanup = determine_repo_dir(
    template='%s',
    abbreviations=config_dict['abbreviations'],
    clone_to_dir=config_dict['cookiecutters_dir'],
    checkout=None,
    no_input=False,
    #password=password,
    #directory=directory,
)
print(repo_dir, end='')" template)))
    (shell-command-to-string
     (format "%s -c \"%s\"" prefab-cookiecutter-python-executable src))))

(defun prefab--cookiecutter-existing-templates ()
  "Return a list of local templates."
  (mapcan #'f-directories prefab-cookiecutter-template-sources))

(defun prefab--alist-to-python-dict (alist)
  "Convert ALIST to a python dictionary (as a string)."
  (format "{%s}" (mapconcat #'identity (cl-loop for (key . value) in alist
                                                collect
                                                (format "'%s': '%s'" key value))
                            ", ")))

(defun prefab--cookiecutter-template-has-replay (template)
  "Return t if TEMPLATE has a replay else false."
  (f-exists-p
   (f-swap-ext (f-join prefab-cookiecutter-replay-dir template) "json")))

(defun prefab--escape-quotes (s)
  "Return S with quotes escaped."
  (replace-regexp-in-string "'" "\\'" s nil t nil 0))

(defun prefab--transient-set-value (template ctx-file original)
  "Set the infixes and suffixes of the prefab transient.

TEMPLATE should be the cookiecutter template, CTX-FILE the cookiecutter
context file path and ORIGINAL should indicate whether to get the default
context from the replay or the original template defaults."
  (let* ((ctx (prefab--cookiecutter-context template ctx-file original))
         (keywords (mapcar (lambda (cell) (symbol-name (car cell))) ctx))
         (key-lookup (prefab--keys keywords '("t" "c")))
         (options (cl-loop for (key-sym . value) in ctx
                           for key = (symbol-name key-sym)
                           collect
                           (list (alist-get key key-lookup)
                                 (replace-regexp-in-string "[_-]+" " " key)
                                 (concat key "="))))
         (v-options (vconcat ["Context"] options))
         (template-options
          (vconcat ["Template"]
                   (list (list "t" "Template" (concat "template=")))
                   (when (prefab--cookiecutter-template-has-replay template)
                     (list (list "-" (if original "Replay Last" "Template defaults")
                                 (lambda () (interactive) (prefab--transient-set-value template ctx-file (not original))) ':transient t))))))
    (transient-replace-suffix 'prefab--uri (list 0) template-options)
    (transient-replace-suffix 'prefab--uri (list 1) v-options)
    (oset (get 'prefab--uri 'transient--prefix)
          :value (cl-loop for (key . value)
                          in (cons (cons 'template template) ctx)
                          collect (format "%s=%s" (symbol-name key) value)))
    (prefab--uri)))

(defun prefab--run (args)
  "Run cookiecutter using ARGS."
  (interactive (list (transient-args transient-current-command)))
  (let* ((template (cadr (split-string (car args) "=")))
         (extra-args
          (mapconcat (lambda (s)
                       (replace-regexp-in-string
                        "=\\(.*\\)$" "=$'\\1'" (prefab--escape-quotes s)))
                     (cdr args) " "))
         (cmd (format "cookiecutter %s --no-input --output-dir %s %s"
                      template prefab-cookiecutter-output-dir extra-args))
         (ctx-alist (mapcar (lambda (c)
                              (let ((sp (split-string c "=")))
                                (cons (car sp)
                                      (prefab--escape-quotes (cadr sp)))))
                            args)))
    (when prefab-debug (message "Running command %s" cmd))
    (let ((response (shell-command-to-string cmd)))
      (if (string-match-p "^Error:" response)
          (message response)
        (dired (prefab--cookiecutter-created-dir
                (f-join (car prefab-cookiecutter-template-sources) template)
                (mapcar (lambda (c) (if (string= (car c) "template")
                                        (cons "_template" (cdr c))
                                      c)) ctx-alist)))))))

(transient-define-prefix prefab--uri ()
  :value '("???=nonempty")
  ["Template"
   ("t" "name" "" read-string)]
  ["Context"
   ("?" "???" "" read-string)]
  ["Actions"
   ("c" "Create"    prefab--run)])

;;; Commands

(defun prefab ()
  "Generate a project from a template."
  (interactive)
  (let* ((templates (prefab--cookiecutter-existing-templates))
         (alist (mapcar (lambda (p) (cons (f-filename p) p)) templates))
         (template (completing-read "Template: "
                                    (or (mapcar #'f-filename templates)
                                        (mapcan #'cdr prefab-default-templates))))
         (template-path (or (alist-get template alist nil nil #'string=)
                            (progn (message "Downloading template %s" template)
                                   (prefab--cookiecutter-download-template template))))
         (ctx-file (format "%s/cookiecutter.json" template-path)))
    (prefab--transient-set-value
     template ctx-file (not prefab-cookiecutter-get-context-from-replay))))

(provide 'prefab)

;;; prefab.el ends here
