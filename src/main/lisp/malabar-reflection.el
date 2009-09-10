;;; malabar-project.el --- Reflection handling for malabar-mode
;;
;; Copyright (c) 2009 Espen Wiborg <espenhw@grumblesmurf.org>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301 USA.
;;
(require 'cl)
(require 'malabar-project)
(require 'malabar-groovy)
(require 'malabar-util)

(require 'arc-mode)

(defvar malabar-java-primitive-types-with-defaults
  '(("byte" . "0")
    ("short" . "0")
    ("int" . "0")
    ("long" . "0L")
    ("float" . "0.0f")
    ("double" . "0.0d")
    ("char" . "'\\0'")
    ("boolean" . "false")))

(defun malabar--type-variable-name-p (class)
  (< (length class) 3))

(defun malabar--primitive-type-p (class)
  (or (assoc class malabar-java-primitive-types-with-defaults)
      (equal class "void")))

(defun malabar--parametrized-type-p (class)
  (position ?< class))

(defun malabar--raw-type (class)
  (malabar--array-element-type
   (substring class 0 (malabar--parametrized-type-p class))))

(defun malabar--array-type-p (class)
  (position ?\[ class))

(defun malabar--array-element-type (class)
  (substring class 0 (malabar--array-type-p class)))

(defun malabar-qualify-class-name-in-buffer (class &optional buffer)
  (cond ((malabar--type-variable-name-p class)
         class)
        ((malabar--primitive-type-p class)
         class)
        ((malabar--array-type-p class)
         (malabar-qualify-class-name-in-buffer (malabar--array-element-type class)))
        ((malabar--parametrized-type-p class)
         (malabar-qualify-class-name-in-buffer (malabar--raw-type class)))
        (t
         (let* ((buffer (or buffer (current-buffer)))
                (package (malabar-get-package-name buffer))
                (class-tag (malabar-class-defined-in-buffer-p class buffer)))
           (if class-tag
               (if package
                   (concat package "." class)
                 class)
             (or (malabar-find-imported-class class buffer)
                 (concat (or package "") "." class)))))))

(define-cached-function malabar-get-class-info (classname &optional buffer)
  (setq buffer (or buffer (current-buffer)))
  (unless (consp classname)
    (or (malabar--get-class-info-from-source classname buffer)
        (malabar-groovy-eval-and-lispeval
         (format "%s.getClassInfo('%s')"
                 (malabar-project-classpath buffer)
                 classname)))))

(defun malabar--get-class-info-from-source (classname buffer)
  ;; First, try resolving in local project
  (let ((file (malabar-project-locate (malabar-class-name-to-filename classname)
                                      (malabar-find-project-file buffer))))
    (if file
        ;; Defined in this project
        (let ((existing-buffer (find-buffer-visiting file)))
          (if existing-buffer
              (malabar--get-class-info-from-buffer existing-buffer)
            (let ((buf (find-file-noselect file)))
              (let ((class-tag (malabar--get-class-info-from-buffer buf)))
                (kill-buffer buf)
                (semantic-tag-deep-copy-one-tag
                 class-tag
                 (lambda (tag)
                   (let ((new-tag (semantic-tag-copy tag nil t)))
                     (when (semantic-tag-bounds tag)
                       (apply 'semantic-tag-set-bounds new-tag (semantic-tag-bounds tag))))))))))
      ;; Not defined here
      (let ((source-jar (malabar--get-source-jar classname buffer)))
        (if (null source-jar)
            ;; Not defined in an accessible source artifact
            ;; TODO:  Try jdk-source?
            nil
          (let ((buffer-name
                 (malabar--archived-source-buffer-name classname source-jar)))
            (if (get-buffer buffer-name)
                (malabar--get-class-info-from-buffer (get-buffer buffer-name))
              (let ((buffer (malabar--load-source-from-zip classname
                                                           source-jar
                                                           buffer-name)))
                (when (buffer-live-p buffer)
                  (malabar--get-class-info-from-buffer buffer))))))))))

(defun malabar--archived-source-buffer-name (classname archive)
  (concat (file-name-nondirectory (malabar-class-name-to-filename classname))
          " (" (file-name-nondirectory archive) ")"))
  
(defun malabar--load-source-from-zip (classname archive buffer-name)
  ;; TODO:  This won't work for inner classes
  (let ((file-name (malabar-class-name-to-filename classname))
        (buffer (get-buffer buffer-name)))
    (or buffer
        (save-excursion
          (setq buffer (get-buffer-create buffer-name))
          (set-buffer buffer)
          (setq buffer-file-name (expand-file-name (concat archive ":" file-name)))
          (setq buffer-file-truename (file-name-nondirectory file-name))
          (let ((exit-code
                 (archive-extract-by-stdout archive file-name
                                            archive-zip-extract)))
            (if (and (numberp exit-code) (zerop exit-code))
                (progn (malabar-mode)
                       (goto-char (point-min))
                       (setq buffer-undo-list nil
                             buffer-saved-size (buffer-size)
                             buffer-read-only t)
                       (set-buffer-modified-p nil)
                       buffer)
              (set-buffer-modified-p nil)
              (kill-buffer buffer)))))))

(defun malabar--get-class-info-from-buffer (buffer)
  (with-current-buffer buffer
    (malabar-get-class-tag-at-point)))

(define-cached-function malabar--get-source-jar (classname buffer)
  (malabar-groovy-eval-and-lispeval
   (format "%s.sourceJarForClass('%s')"
           (malabar-project buffer)
           classname)))

(defun malabar--get-name (tag)
  (semantic-tag-name tag))

(defun malabar--get-return-type (tag)
  (semantic-tag-type tag))

(defun malabar--get-type (tag)
  (semantic-tag-type tag))

(defun malabar--get-throws (tag)
  (semantic-tag-function-throws tag))

(defun malabar--get-arguments (tag)
  (semantic-tag-function-arguments tag))

(defun malabar--get-type-parameters (tag)
  (semantic-tag-get-attribute tag :template-specifier))

(defun malabar--get-declaring-class (tag)
  (semantic-tag-get-attribute tag :declaring-class))

(defun malabar--get-super-class (tag)
  (semantic-tag-type-superclasses tag))

(defun malabar--get-interfaces (tag)
  (semantic-tag-type-interfaces tag))

(defun malabar--get-modifiers (tag)
  (semantic-tag-modifiers tag))

(defmacro define-tag-modifier-predicates (&rest props)
  `(progn
     ,@(mapcar (lambda (p)
                 (let ((s (symbol-name p)))
                   `(defun ,(intern (format "malabar--%s-p" s)) (tag)
                      (member ,s (malabar--get-modifiers tag)))))
               props)))

(define-tag-modifier-predicates
  abstract
  public
  private
  protected
  final
  interface)

(defun malabar--package-private-p (tag)
  (not (or (malabar--public-p tag)
           (malabar--protected-p tag)
           (malabar--private-p tag))))

(defun malabar--method-p (tag)
  (eq (semantic-tag-class tag) 'function))

(defun malabar--constructor-p (tag)
  (and (malabar--method-p tag)
       (semantic-tag-function-constructor-p tag)))

(defun malabar--class-p (tag)
  (eq (semantic-tag-class tag) 'type))

(defun malabar--field-p (tag)
  (eq (semantic-tag-class tag) 'variable))

(defun malabar-get-members (classname &optional buffer)
  (malabar--get-members (malabar-get-class-info classname buffer)))

(defun malabar--get-members (class-tag)
  (semantic-tag-type-members class-tag))

(defun malabar-get-abstract-methods (classname &optional buffer)
  (malabar--get-abstract-methods (malabar-get-class-info classname buffer)))

(defun malabar--get-abstract-methods (class-info)
  (remove-if-not (lambda (m)
                   (and (malabar--method-p m)
                        (malabar--abstract-p m)))
                 (malabar--get-members class-info)))

(defun malabar--arg-name-maker ()
  (lexical-let ((counter -1))
    (lambda (arg)
      (or (getf arg :name)
          (format "arg%s"
                  (incf counter))))))

(defun malabar--cleaned-modifiers (tag)
  (remove 'native (remove 'abstract (malabar--get-modifiers spec))))

(defun malabar-create-simplified-signature (tag)
  "Creates a readable signature suitable for
e.g. `malabar-choose'."
  (let ((s (semantic-format-tag-uml-prototype tag)))
    (if (assoc (substring s 0 1) semantic-format-tag-protection-image-alist)
        (substring s 1)
      s)))

(defun malabar--stringify-arguments (arguments)
  (concat "("
          (mapconcat (malabar--arg-name-maker)
                     arguments
                     ", ")
          ")"))

(defun malabar-create-method-signature (tag)
  "Creates a method signature for insertion in a class file."
  (let ((tag (semantic-tag-copy tag)))
    (semantic-tag-put-attribute tag :typemodifiers
                                (remove "abstract"
                                        (remove "native"
                                                (malabar--get-modifiers tag))))
    (semantic-format-tag-prototype tag)))

(defun malabar-create-constructor-signature (tag)
  "Creates a constructor signature for insertion in a class file."
  (malabar-create-method-signature
   (semantic-tag-copy tag (semantic-tag-name (malabar-get-class-tag-at-point)))))

(defun malabar-make-choose-spec (tag)
  (cons (malabar-create-simplified-signature tag)
        tag))

(defun malabar-default-return-value (type)
  (let ((cell (assoc type malabar-java-primitive-types-with-defaults)))
    (if cell
        (cdr cell)
      "null")))

(defun malabar--class-accessible-p (qualified-class class-info)
  (or (malabar--public-p class-info)
      (equal (malabar-get-package-name) (malabar-get-package-of qualified-class))))

(define-cached-function malabar-qualify-class-name (unqualified &optional buffer)
  (malabar-groovy-eval-and-lispeval
   (format "%s.getClasses('%s')"
           (malabar-project-classpath (or buffer (current-buffer)))
           unqualified)))

(defun malabar--get-type-tag (typename &optional buffer)
  (malabar-get-class-info typename buffer))

(provide 'malabar-reflection)

;; Local Variables:
;; byte-compile-warnings:(not cl-functions)
;; End:
