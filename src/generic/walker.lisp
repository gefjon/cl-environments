;;;; walker.lisp
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

;;; Code-Walker Macro

(defmacro %walk-form (form &environment env)
  "Code-walker macro, forms to be walked are enclosed in this
   macro. When the macro is expanded by the CL implementation the
   code-walker function WALK-FORM is called."
  
  (walk-form form env))

(defun enclose-form (form)
  "Encloses FORM in the code-walker macro."
  
  `(%walk-form ,form))

(defun enclose-forms (forms)
  "Encloses each form, in FORMS, in the code-walker macro."
  
  (mapcar #'enclose-form forms))


;;; Code-Walker function

(defun walk-form (form env)
  "Code walker function. Surrounds the sub-forms in the code-walker
   macro. When walking forms which create a lexical environment, an
   `environment' object is created containing the lexical binding and
   declaration information."
  
  (match form
    ((cons op args)
     (walk-fn-form op args env))

    (_ (walk-atom-form form env))))


;;; Walking atom forms

(defun walk-atom-form (form env)
  "Walks atom forms. If the form is a symbol-macro, expands the macro
   and encloses the expansion in the code-walker macro, otherwise
   returns the form as is."
  
  (multiple-value-bind (form expanded-p) (macroexpand-1 form env)
    (if expanded-p
	(enclose-form form)
	form)))


;;; Walking function call forms

(defgeneric walk-fn-form (op args env)
  (:documentation
   "Walks a function call expression with function/macro/special
    operator OP and arguments ARGS."))


(defmethod walk-fn-form (op args env)
  "Walks a function call expression which is not one of the recognized
   CL special forms. If OP names a macro it is expanded and the
   expansion is enclosed in the code-walker macro. If OP is a special
   operator the function call expression is simply returned as is (the
   arguments are not walked. If OP is neither a macro nor special
   operator it is assumed to be a function, the function call
   expression is returned with the arguments enclosed in the the
   code-walker macro."
  
  (multiple-value-bind (form expanded-p) (macroexpand-1 (cons op args) env)
    (cond
      (expanded-p
       (enclose-form form))
      ((special-operator-p op)
       (cons op args)) ; Cannot be walked
      (t
       (cons op
	     (if (proper-list-p args)
		 (enclose-forms args)
		 args))))))


;;; Code walker definition macro

(defmacro! defwalker (op (arg-var &optional (env-var (gensym))) &body body)
  "Defines a code-walker method for the operator OP. ARG-VAR is bound
   to the operator arguments and ENV-VAR is bound to the lexical
   environment in which the operator appears. The forms in BODY,
   enclosed in an implicit PROGN, should return the new operator
   arguments. The result returned by the walker method is the form
   with the operator OP and the arguments returned by the last form in
   BODY, effectively (CONS ,OP (PROGN ,@BODY))."
  
  (multiple-value-bind (body decl doc)
      (parse-body body :documentation t)
    
    `(defmethod walk-fn-form ((,g!op (eql ',op)) ,arg-var (,env-var t))
       ,@(ensure-list doc) ,@decl

       (flet ((call-next-walker ()
		(call-next-method)))
	 (cons ,g!op (skip-walk-errors ,@body))))))
     
