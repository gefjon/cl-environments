;;;; let-forms.lisp
;;;;
;;;; Copyright 2017 Alexander Gutev
;;;;
;;;; Permission is hereby granted, free of charge, to any person
;;;; obtaining a copy of this software and associated documentation
;;;; files (the "Software"), to deal in the Software without
;;;; restriction, including without limitation the rights to use,
;;;; copy, modify, merge, publish, distribute, sublicense, and/or sell
;;;; copies of the Software, and to permit persons to whom the
;;;; Software is furnished to do so, subject to the following
;;;; conditions:
;;;;
;;;; The above copyright notice and this permission notice shall be
;;;; included in all copies or substantial portions of the Software.
;;;;
;;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
;;;; OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;;;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
;;;; OTHER DEALINGS IN THE SOFTWARE.

(in-package :cl-environments)

;;; Let forms

(defmethod walk-fn-form ((op (eql 'cl:let)) args env)
  "Walks LET binding forms, augments the environment ENV with the
   bindings introduced, adds the declaration information to the
   bindings and encloses the body of the LET form in the augmented
   environment."
  
  (destructuring-bind (bindings . body) args
    (let* ((old-env (get-environment env))
	   (new-env (copy-environment old-env)))
      `(let ,(walk-let-bindings bindings new-env)
	 ,@(walk-body body new-env)))))

(defun walk-let-bindings (bindings env)
  "Walks the bindings of a LET form. Adds the variable bindings to the
   environment ENV and encloses the initforms of the bindings (if any)
   in the code walking macro. Returns the new bindings list."
  
  (flet ((enclose-binding (binding)
	   (match binding
	     ((list var initform)
	      `(,var ,(enclose-form initform)))
	     (_ binding))))
    (iter (for binding in bindings)
	  (add-variable (ensure-car binding) env)
	  (collect (enclose-binding binding)))))

(defun walk-body (body ext-env &optional documentation)
  "Walks the body of forms which create a local environment, such as
   LET forms, LAMBDA, DEFUN, LOCALLY. Adds the declaration information
   to the bindings in the environment EXT-ENV, and encloses the body
   in the augmented environment. If DOCUMENTATION is true the body may
   contain a documentation string preceeding or following the
   declarations."
  
  (multiple-value-bind (forms decl docstring)
      (parse-body body :documentation documentation)
    `(,@(ensure-list docstring)
      ,@(walk-declarations decl ext-env)
	,(enclose-in-env
	  ext-env
	  (enclose-forms forms)))))


(defmethod walk-fn-form ((op (eql 'cl:let*)) args env)
  "Walks LET* binding forms: encloses each initform in an environment
   containing all the variables in the preceeding bindings. Encloses
   the body in an environment containing all the variable bindings."
  
  (destructuring-bind (bindings . body) args
    (let* ((env (get-environment env))
	   (body-env (add-let*-vars bindings env))
	   (body (walk-body body body-env))
	   (bindings (walk-let*-bindings bindings env body-env)))

      `(cl:let* ,bindings ,@body))))

(defun add-let*-vars (bindings env)
  "Creates a new environment, which is a copy of ENV, and adds
   variable bindings for each variable introduced by the LET*."
  
  (let ((env (copy-environment env)))
    (dolist (binding bindings env)
      (add-variable (ensure-car binding) env))))

(defun walk-let*-bindings (bindings env body-env)
  "Walks the bindings of a LET*. ENV is the environment containing the
   LET* form and BODY-ENV is the environment in which the body of the
   LET* form is enclosed, i.e. the environment containing all the
   bindings introduced by the LET*. Each initform is enclosed in an
   environment which contains the all previous bindings copied from
   BODY-ENV."
  
  (flet ((enclose-binding (binding env)
	   (match binding
	     ((list var initform)
	      `(,var ,(enclose-in-env env (list (enclose-form initform)))))
	     (_ binding))))
    (iter
      (for binding in bindings)
      (collect (enclose-binding binding env))
      
      (setf env (copy-environment env))
      (let ((var (ensure-car binding)))
	(setf (variable-binding var env)
	      (variable-binding var body-env))))))

;;; Destructuring Bind

(defmethod walk-fn-form ((op (eql 'cl:destructuring-bind)) args env)
  "Walks DESTRUCTURING-BIND forms. The body of the DESTRUCTURING-BIND
   is enclosed in an environment containing all the variables in the
   lambda-list. The expression form is enclosed in the code walking
   macro."
  
  (let ((env (get-environment env)))
    (destructuring-bind (lambda-list form . body) args
      (multiple-value-bind (lambda-list env)
	  (walk-lambda-list lambda-list env :destructure t)
	`(cl:destructuring-bind ,lambda-list ,(enclose-form form)
	   ,@(walk-body body env))))))


;;; Lambda

(defmethod walk-fn-form ((op (eql 'cl:lambda)) args env)
  "Walks LAMBDA forms, the body is enclosed in an environment
   containing all the variables in the lambda-list."
  
  (let ((env (get-environment env)))
    (destructuring-bind (lambda-list . body) args
      (multiple-value-bind (lambda-list env)
	  (walk-lambda-list lambda-list env)
	`(cl:lambda ,lambda-list
	   ,@(walk-body body env))))))



;;; Lexical functions

(defmethod walk-fn-form ((op (eql 'cl:flet)) args env)
  "Walks FLET forms. The functions introduced by the FLET are added to
   a copy of the environment ENV, and the body, of the FLET form, is
   enclosed in this environment. The body of each function is enclosed
   in an environment containing the variables in the function's lambda
   list, the environment however does not contain the function names."
  
  (let* ((env (get-environment env))
	 (new-env (copy-environment env)))
    (destructuring-bind (fns . body) args
      `(flet ,(mapcar (rcurry #'walk-local-fn env new-env) fns)
	 ,@(walk-body body new-env)))))

;; TODO:
;;
;; inline/notinline declarations in labels body have to be copied over
;; to the bodies of the functions in labels, since every function in
;; labels can call any other function in labels. No other declarations
;; should be copied.
;;
;; inline/notinline declarations have to be extracted from body and
;; applied to the bodies of the functions defined by the labels form.
;;
;; CCL does not follow this rule.
;;
(defmethod walk-fn-form ((op (eql 'cl:labels)) args env)
  "Walks LABELS forms. The functions introduced by the LABELS are
   added to a copy of the environment ENV, and the body, of the LABELS
   form, is enclosed in this environment. The body of each function is
   enclosed in an environment containing: all the functions,
   introduced by the LABELS, and the variables in the function's
   lambda list."
  
  (let ((env (copy-environment (get-environment env))))
    (flet ((walk-local-fn (def)
	     (cons (first def) (walk-fn-def def env))))
      (destructuring-bind (fns . body) args
	(mapc (compose (rcurry #'add-function env) #'first) fns)
	`(cl:labels ,(mapcar #'walk-local-fn fns)
	   ,@(walk-body body env))))))


(defun walk-local-fn (def fn-env new-env)
  "Walks a lexical function, defined using FLET or LABELS. Adds the
   function to the environment NEW-ENV and encloses the body of the
   function in a copy of the environment FN-ENV containing the
   variables introduced by the function's lambda list."
  
  (destructuring-bind (name . def) def
    (add-function name new-env)
    `(,name ,@(walk-fn-def def fn-env))))

(defun walk-fn-def (def env)
  "Walks a function definition, DEF is a list where the first element
   is the function's lambda-list and the rest of the elements are the
   function's body. The variables introduced by the lambda-list are
   added to a copy of the environment ENV, the body is enclosed in
   this environment. The new lambda-list and body is returned. This
   function can be used both for lexical function definitions and for
   global function definitions."
  
  (destructuring-bind (lambda-list . body) def
    (multiple-value-bind (lambda-list env)
	(walk-lambda-list lambda-list env)
      `(,lambda-list
	,@(walk-body body env t)))))


;;; Lexical Macros

(defmethod walk-fn-form ((op (eql 'cl:macrolet)) args env)
  "Walks MACROLET forms. Each macro is added to a copy of the
   environment ENV, and the body of the MACROLET form is enclosed in
   this environment. The body of each macro is enclosed in an
   environment containing the variables introduced by the macro's
   lambda-list, but does not contain the macro's themselves."
  
  (destructuring-bind (macros . body) args
    (let* ((env (get-environment env))
	   (new-env (copy-environment env)))
      `(cl:macrolet ,(mapcar (rcurry #'walk-local-macro env new-env) macros)
	 ,@(walk-body body new-env)))))

(defun walk-local-macro (def mac-env new-env)
  "Walks a lexical macro, defined using MACROLET. Adds the macro to
   the environment NEW-ENV and encloses the body of the macro in a
   copy of the environment MAC-ENV containing the variables introduced
   by the macro's lambda list."
  
  (destructuring-bind (name . def) def
    (add-function name new-env :type :macro)
    `(,name ,@(walk-macro-def def mac-env))))

(defun walk-macro-def (def env)
  "Walks a macro definition, DEF is a list where the first element is
   the macro's lambda-list and the rest of the elements are the
   macro's body. The variables introduced by the lambda-list are added
   to a copy of the environment ENV, the body is enclosed in this
   environment. The new lambda-list and body is returned. This
   function can be used both for lexical macro definitions and for
   global macro definitions."
  
  (destructuring-bind (lambda-list . body) def
    (multiple-value-bind (lambda-list env)
	(walk-lambda-list lambda-list env :destructure t :env t)
      `(,lambda-list
	,@(walk-body body env t)))))


;;; Lexical Symbol Macros

(defmethod walk-fn-form ((op (eql 'cl:symbol-macrolet)) args env)
  "Walks SYMBOL-MACROLET forms. Each symbol macro is added to a copy
   of the environment ENV, and the body is enclosed in this
   environment."
  
  (destructuring-bind (macros . body) args
    (let ((env (copy-environment (get-environment env))))
      (mapc (compose (rcurry #'add-symbol-macro env) #'first) macros)
      `(cl:symbol-macrolet ,macros
	 ,@(walk-body body env)))))