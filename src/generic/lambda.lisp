;;;; lambda.lisp
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


(define-condition malformed-lambda-list (walk-program-error)
  ((list-position
    :reader list-position
    :initarg :position)))

(defun lambda-walk-error (list)
  "Signals a `MALFORMED-LAMBDA-LIST' condition for the lambda list at
   position LIST. A SKIP-WALK restart is established which simply
   returns NIL."
  
  (restart-case
      (error 'malformed-lambda-list :position list)
    (skip-walk ())))


(defun lambda-list-keyword-p (sym)
  "Checks wether SYM names a lambda list keyword, i.e. checks whether
   SYM is a member of LAMBDA-LIST-KEYWORDS."
  
  (member sym lambda-list-keywords))

(defun var-symbol-p (thing)
  (and thing (symbolp thing) (not (keywordp thing)) (lambda-list-keyword-p thing)))


;; TODO: Does not raise an error when there are two &allow-other-key
;; in succession, add error checking for this case.
(defun map-lambda-list (fn list &key ((:destructure destructurep)) ((:env envp)))
  "Applies FN on each element of the lambda list LIST, the result
   returned by FN are accumulated into a new list, which is returned
   from the function. FN is called with two arguments: the type of
   argument and the argument itself. The type can be either: :REQUIRED
   for required arguments, :OPTIONAL for optional arguments, :REST for
   rest arguments, :KEY for keyword arguments, :AUX for auxiliary
   variables, :WHOLE for whole destructuring arguments, :ENVIRONMENT
   for environment arguments or NIL for the lambda-list keywords
   themselves. If FN returns NIL for a particular element, that
   element is not inserted into the resulting lambda
   list. If :DESTRUCTURE is true then lambda-list is parsed as a
   destructuring lambda list, if :ENV is true then &ENVIRONMENT
   parameters are allowed. If a syntax error is encountered in the
   lambda-list (incorrect position of lambda-list keywords) a
   `MALFORMED-LAMBDA-LIST' condition is signaled with a SKIP-WALK
   restart, which simply resumes processing as though the lambda list
   keyword appeared in the correct position. The arguments themselves
   are not checked for correct syntax, it is the responsibility of FN
   to do so."
  
  (declare (special envp))

  (let* (new-list
	 (collector (make-simple-collector-to-place new-list)))
    (declare (special collector))

    (labels
	((map-collect (state thing)
	   (awhen (funcall fn state thing)
	     (funcall collector it)))

	 (collect (state &rest things)
	   (mapc (curry #'map-collect state) things))
	 
	 (guard (condition list)
	   (unless condition
	     (lambda-walk-error list)))

	 (consume-arg (state list)
	   (match list
	     ((list* (guard arg (not (lambda-list-keyword-p arg))) rest)
	      (collect state arg)
	      rest)
	     
	     (_
	      (lambda-walk-error list)
	      list))))

      (match-state list
	(:whole
	 (and (cons '&whole rest) list)

	 (guard (and destructurep (eq from-state :start)) list)
	 (collect nil '&whole)
	 
	 (next (consume-arg :whole rest) :from :required))

	(:optional
	 (and (cons '&optional rest) list)

	 (guard (member from-state '(:start :required)) list)
	 (collect nil '&optional)

	 (next rest))

	(:rest
	 (and (cons (and (or '&rest '&body) keyword) rest) list)

	 (guard (and (or (eq keyword '&rest) destructurep)
		     (member from-state '(:start :required :optional))) list)
	 
	 (collect nil keyword)
	 (next (consume-arg :rest rest)))

	(:key
	 (and (cons '&key rest) list)

	 (guard (member from-state '(:start :required :optional :rest)) list)
	 (collect nil '&key)

	 (next rest))

	(:allow-other-keys
	 (and (cons '&allow-other-keys rest) list)

	 (guard (eq from-state :key) list)
	 (collect nil '&allow-other-keys)

	 (next rest :from :key :force t))

	(:aux
	 (cons '&aux rest)

	 (collect nil '&aux)
	 (next rest))

	(:environment
	 (and (cons '&environment rest) list)

	 (guard envp list)
	 (setf envp nil)

	 (collect nil '&environment)
	 (next (consume-arg :environment rest) :from from-state :force t))

	;; Argument states

	(:required
	 (guard (cons (guard var-list (listp var-list)) rest) destructurep)
	 :from (:start :required)

	 (let (new-list)
	   (let ((collector (make-simple-collector-to-place new-list))
		 (envp nil))
	     (declare (special collector envp))
	     (next var-list :from :start))
	   (funcall collector new-list))
	 
	 (next rest))

	(:required
	 (cons var rest)
	 :from (:start :required)

	 (collect :required var)
	 (next rest))
	
	(arg
	 (cons var rest)
	 :from (:optional :key :aux)

	 (collect from-state var)
	 (next rest :from from-state))

	(end-of-list nil)

	(dotted-list
	 (guard var (atom var))

	 (guard (and destructurep (member from-state '(:required :optional))) var)

	 (awhen (funcall fn :rest var)
	   (nconc new-list it)))

	(else
	 rest
	 (lambda-walk-error rest)
	 (nconc new-list rest)))
      
      new-list)))

(defun walk-lambda-list (list env &key ((:destructure destructurep)) ((:env envp)))
  "Walks the lambda list LIST, augments the environment ENV with the
   bindings introduced by the lambda list, and encloses the initforms
   of the arguments in the environments augmented with the bindings
   introduced before that argument in the lambda list. Returns the new
   lambda list and the augmented environment. The keyword
   argument :DESTRUCTURE indicates whether the lambda list should be
   treated as a destructuring lambda list, :ENV whether &ENVIRONMENT
   parameters are accepted and :GENERIC whether the lambda list is a
   DEFMETHOD lambda list. This function performs a best effort, that
   is it does not check for all syntax errors and if a syntax error is
   found, it simply returns the rest of the lambda list letting,
   leaving the CL implementation to deal with the error."

  (let ((env (copy-environment env)))
    (flet ((walk-arg (type arg)
	     (multiple-value-bind (arg new-env)
		 (walk-lambda-list-arg type arg env)
	       (setf env new-env)
	       arg)))

      (handler-bind
	  ((malformed-lambda-list #'skip-walk))
	(map-lambda-list #'walk-arg list
			 :destructure destructurep
			 :env envp)))))

(defgeneric walk-lambda-list-arg (type arg env))

(defmethod walk-lambda-list-arg ((type (eql nil)) keyword env)
  (values keyword env))

(defmethod walk-lambda-list-arg ((type (eql :optional)) arg env)
  (match arg
    ((or (list var initform var-sp)
	 (list var initform)
	 (list var)
	 var)

     (values
      `(,var ,(enclose-in-env env (list initform)) ,var-sp)
      (aprog1 (copy-environment env)
	(add-variable var it)
	(when var-sp (add-variable var-sp it)))))

    (_ (values arg env))))

(defmethod walk-lambda-list-arg ((type (eql :key)) arg env)
  (match arg
    ((or (cons
	   (and (or (list keyword var)
		    var)
		arg)
	   (or
	    (list initform var-sp)
	    (list initform)
	    nil))
	  (and var arg))

     (values
      `(,arg ,(enclose-in-env env (list initform)) ,var-sp)
      (aprog1 (copy-environment env)
	(add-variable var it)
	(when var-sp (add-variable var-sp it)))))
    
    (_ (values arg env))))

(defmethod walk-lambda-list-arg ((type (eql :aux)) arg env)
  (match arg
    ((or (list var initform)
	 (list var)
	 var)

     (values
      `(,var ,(enclose-in-env env (list initform)))
      (aprog1 (copy-environment env)
	(add-variable var it))))
    (_ (values arg env))))

(defmethod walk-lambda-list-arg ((type t) arg env)
  (add-variable arg env)
  (values arg env))
