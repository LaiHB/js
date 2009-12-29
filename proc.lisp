(in-package :js)

(defparameter *label-name* nil)

(defparameter *lexenv-chain* nil)

(defun traverse-form (form)
  (declare
   (special env locals obj-envs lmbd-forms *toplevel*))
  (cond ((null form) nil)
	((atom form)
	 (if (keywordp form)
	     (js-intern form) form))
	(t
	 (case (car form)
	   ((:var)
	      (cons (js-intern (car form))
		    (list (mapcar
			   (lambda (var-desc)
			     (let ((var-sym (->sym (car var-desc))))
			       (set-add env var-sym)
			       (set-add locals var-sym)
			       (cons (->sym (car var-desc))
				     (traverse-form (cdr var-desc)))))
			   (second form)))))
	   ((:label)
	      (let ((*label-name* (->sym (second form))))
		(traverse-form (third form))))
	   ((:for)
	      (let* ((label *label-name*)
		     (*label-name* nil))
		(list (js-intern (car form)) ;for
		      (traverse-form (second form)) ;init
		      (traverse-form (third form))  ;cond
		      (traverse-form (fourth form)) ;step
		      (traverse-form (fifth form)) ;body
		      label)))
	   ((:while) (traverse-form
		      (list (js-intern :for)
			    nil (second form)
			    nil (third form) *label-name*)))
	   ((:do)
	      (let* ((label *label-name*)
		     (*label-name* nil))
		(list (js-intern (car form))
		      (traverse-form (second form))
		      (traverse-form (third form))
		      label)))
;;;todo: think about removing interning from :dot and :name to macro expander (see :label)
	   ((:name) (list (js-intern (car form)) (->sym (second form))))
	   ((:dot) (list (js-intern (car form)) (traverse-form (second form))
			 (->sym (third form))))
	   ((:with)
	      (let* ((*lexenv-chain* (cons :obj *lexenv-chain*))
		     (placeholder (copy-list *lexenv-chain*))) ;;todo: copy env
		(push placeholder obj-envs)
		(list (js-intern (car form))
		      placeholder
		      (traverse-form (second form))
		      (traverse-form (third form)))))
	   ((:function :defun)
	      (unless *toplevel*
		(when (and (eq (car form) :defun)
			   (second form))
		  (let ((fun-name (->sym (second form))))
		    (set-add env fun-name)
		    (set-add locals fun-name))))
	      (let ((placeholder (list (car form))))
		(queue-enqueue lmbd-forms (list form env placeholder (copy-list *lexenv-chain*)))
		placeholder))
	   ((:toplevel)
	      (let ((*lexenv-chain* (cons :obj *lexenv-chain*)))
		(list (js-intern (car form))
		      (copy-list *lexenv-chain*)
		      (traverse-form (second form)))))
	   (t (mapcar #'traverse-form form))))))

(flet ((dump (el)
	 (or (and (symbolp el) el) (set-elems el))))
  (defun dump-lexenv-chain ()
    (mapcar #'dump *lexenv-chain*))
  (defun transform-obj-env (place)
    (setf (car place) (dump (car place)))
    (setf (cdr place) (mapcar #'dump (cdr place)))))

(defparameter *toplevel* nil)
(defun shallow-process-toplevel-form (form)
  (let* (*lexenv-chain*
	 (env (set-make))
	 (locals (set-make))
	 (obj-envs nil)
	 (*toplevel* t)
	 (new-form (traverse-form form)))
    (declare (special env locals obj-envs))
    (mapc #'transform-obj-env obj-envs)
    (let ((toplevel-vars (set-elems env)))
      (set-remove-all env)
      (append (list (car new-form) toplevel-vars)
	      (cdr new-form)))))

(defun lift-defuns (form)
  (let (defuns oth)
    (loop for el in form do
      (if (eq (car el) :defun) (push el defuns)
	  (push el oth)))
    (append (reverse defuns) (reverse oth))))

(defun shallow-process-function-form (form old-env lexenv-chain)
  (let* ((env (set-copy old-env))
	 (*lexenv-chain* (cons env lexenv-chain))
	 (locals (set-make))
	 (arglist (mapcar #'->sym (third form)))
	 (obj-envs nil)
	 (new-form (traverse-form (fourth form)))
	 (name (and (second form) (->sym (second form)))))
    (declare (special env locals obj-envs))
    (mapc (lambda (arg) (set-add env arg)) arglist)
    (mapc #'transform-obj-env obj-envs)
    (set-add env name) ;;inject function name (if any) into it's lexical environment
    (list (js-intern (first form)) ;;defun or function
	  (dump-lexenv-chain) ;;
	  name arglist (set-elems locals) (lift-defuns new-form))))

(defun process-ast (ast)
  (assert (eq :toplevel (car ast)))
  (let ((lmbd-forms (queue-make)))
    (declare (special lmbd-forms))
    (let ((toplevel (shallow-process-toplevel-form ast)))
      (loop until (queue-empty? lmbd-forms)
	    for (form env position lexenv-chain) = (queue-dequeue lmbd-forms) do
	      (let ((funct-form (shallow-process-function-form form env lexenv-chain)))
		(setf (car position) (car funct-form)
		      (cdr position) (cdr funct-form))))
      toplevel)))
