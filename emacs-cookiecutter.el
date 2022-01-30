;;; emacs-cookiecutter.el --- Emacs integration for cookiecutter -*- lexical-binding: t -*-

;; Author: Laurence Warne
;; Maintainer: Laurence Warne
;; Version: 0.1
;; Homepage: https://github.com/laurencewarne/emacs-cookiecutter
;; Package-Requires: ((emacs "27.1") (f "0.2.0") (transient "0.3.0"))


;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; Emacs integration for cookiecutter

;;; Code:

(require 'python)
(require 'json)
(require 'f)


(defgroup cookiecutter nil
  "Emacs integration for cookiecutter."
  :group 'applications)

(defcustom cookiecutter-template-sources
  (list (format "%s/.cookiecutters" (getenv "HOME")))
  "List of directories to search for cookiecutter templates.")

(defcustom cookiecutter-output-dir
  (format "%s/projects" (getenv "HOME"))
  "Where to output projects generated by cookiecutter.")

(defconst cookiecutter-version "0.1.0")

(defconst cookiecutter-config-py
  "from cookiecutter.config import get_user_config
from cookiecutter.generate import generate_context
from cookiecutter.replay import load
import json

config_dict = get_user_config()
ctx = load(config_dict['replay_dir'], '%s')
")

;; #ctx_ = generate_context(
;; #    context_file='%s',
;; #    default_context=config_dict['default_context'],
;; #)
(defun cookiecutter--context (template ctx-file)
  "Return the cookiecutter context for TEMPLATE CTX-FILE."
  (let ((src (format (concat cookiecutter-config-py "
print(json.dumps(dict(ctx['cookiecutter'])))") template)))
    (json-read-from-string
     (shell-command-to-string
      (format "%s -c \"%s\"" python-shell-interpreter src)))))

(defun cookiecutter--created-dir (template-dir ctx-file)
  "Return the created directory implied by TEMPLATE-DIR and CTX-FILE."
  (let ((src (format (concat cookiecutter-config-py "
from cookiecutter.find import find_template
from cookiecutter.environment import StrictEnvironment
import os.path

template_dir = find_template('%s')
dirname = os.path.split(template_dir)[1]
envvars = ctx.get('cookiecutter', {}).get('_jinja2_env_vars', {})
env = StrictEnvironment(context=ctx, keep_trailing_newline=True, **envvars)
output_dir = '%s'

name_tmpl = env.from_string(dirname)
rendered_dirname = name_tmpl.render(**ctx)
dir_to_create = os.path.normpath(os.path.join(output_dir, rendered_dirname))
print(dir_to_create, end='')") ctx-file template-dir cookiecutter-output-dir)))
    (shell-command-to-string
      (format "%s -c \"%s\"" python-shell-interpreter src))))

(defun cookiecutter--download-template (template)
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
      (format "%s -c \"%s\"" python-shell-interpreter src))))

(defun cookiecutter--existing-templates ()
  "Return a list of local templates."
  (mapcan #'f-directories cookiecutter-template-sources))

(defun cookiecutter ()
  "Run cookiecutter."
  (interactive)
  (let* ((templates (cookiecutter--existing-templates))
         (alist (mapcar (lambda (p) (cons (f-filename p) p)) templates))
         (template (completing-read "Template: " (mapcar #'f-filename templates)))
         (template-path (or (alist-get template alist nil nil #'string=)
                            (progn (message "Downloading template %s" template)
                                   (cookiecutter--download-template template))))
         (ctx-file (format "%s/cookiecutter.json" template-path))
         (ctx (cookiecutter--context template ctx-file))
         (options (cl-loop for (key-sym . value) in ctx
                           for key = (symbol-name key-sym)
                           collect
                           (list (substring key 0 1)
                                 (replace-regexp-in-string "[_-]+" " " key)
                                 (concat key "="))))
         (v-options (vconcat ["Context"] options))
         (template-options
          (vconcat ["Template"]
                   (list (list "t" "Template" (concat "template="))))))
    (transient-replace-suffix
      'cookiecutter--ui
      (list 0)
      template-options)
    (transient-replace-suffix
      'cookiecutter--ui
      (list 1)
      v-options)
    (oset (get 'cookiecutter--ui 'transient--prefix)
          :value (cl-loop for (key . value)
                          in (cons (cons 'template template) ctx)
                          collect (format "%s=%s" (symbol-name key) value)))
    (cookiecutter--ui)
    (print (cookiecutter--created-dir template-path ctx-file))))

;; (cookiecutter--context "emacs-package-template" "/home/laurencewarne/.cookiecutters/emacs-package-template/cookiecutter.json")

(transient-define-prefix cookiecutter--ui ()
  :value '("???=nonempty")
  ["Template"
   ("t" "name" "" read-string)]
  ["Context"
   ("?" "???" "" read-string)]
  ["Actions"
   ("c" "Create"    cookiecutter--run)])

(defun cookiecutter--run (args)
  "Run cookiecutter using ARGS."
  (interactive (list (transient-args transient-current-command)))
  (let* ((template (cadr (split-string (car args) "=")))
         (extra-args
          (mapconcat (lambda (s)
                       (replace-regexp-in-string "=\\(.*\\)$" "='\\1'" s))
                     (cdr args) " "))
         (cmd (format "cookiecutter %s --no-input --output-dir %s %s" template cookiecutter-output-dir extra-args)))
    (message "Running command %s" cmd)
    (shell-command cmd (generate-new-buffer "cookiecutter"))))

(provide 'emacs-cookiecutter)

;;; emacs-cookiecutter.el ends here
