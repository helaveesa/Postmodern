(defpackage :s-sql
  (:use :common-lisp)
  (:export #:smallint
           #:bigint
           #:numeric
           #:real
           #:double-precision
           #:bytea
           #:text
           #:varchar
           #:db-null
           #:sql-type-name
           #:*standard-sql-strings*
           #:sql-escape-string
           #:from-sql-name
           #:to-sql-name
           #:sql-ize
           #:*escape-sql-names-p*
           #:sql
           #:sql-compile
           #:sql-template
           #:$$
           #:register-sql-operators
           #:enable-s-sql-syntax))

(in-package :s-sql)

;; Utils

(defun strcat (args)
  "Concatenate a list of strings into a single one."
  (let ((result (make-string (reduce #'+ args :initial-value 0 :key 'length))))
    (loop :for pos = 0 :then (+ pos (length arg))
          :for arg :in args
          :do (replace result arg :start1 pos))
    result))

(defun implode (sep list)
  "Reduce a list of strings to a single string, inserting a separator
between them."
  (strcat (loop :for element :on list
                :collect (car element)
                :if (cdr element)
                :collect sep)))

(defun split-on-keywords% (shape list)
  "Helper function for split-on-keywords. Extracts the values
associated with the keywords from an argument list, and checks for
errors."
  (let ((result ()))
    (labels ((next-word (words values)
               (if words
                   (let* ((me (intern (symbol-name (caar words)) :keyword))
                          (optional (member '? (car words)))
                          (multi (member '* (car words)))
                          (no-args (member '- (car words)))
                          (found (position me values)))
                     (cond (found
                            (let ((after-me (nthcdr (1+ found) values)))
                              (unless (or after-me no-args)
                                (error "Keyword ~A encountered at end of arguments." me))
                              (let ((next (next-word (cdr words) after-me)))
                                (cond
                                  (no-args (unless (zerop next) (error "Keyword ~A does not take any arguments." me)))
                                  (multi (unless (>= next 1) (error "Not enough arguments to keyword ~A." me)))
                                  (t (unless (= next 1) (error "Keyword ~A takes exactly one argument." me))))
                                (push (cons (caar words) (if no-args t (subseq after-me 0 next))) result)
                                found)))
                           (optional
                            (next-word (cdr words) values))
                           (t (error "Required keyword ~A not found." me))))
                   (length values))))
      (unless (= (next-word shape list) 0)
        (error "Arguments do not start with a valid keyword."))
      result)))

(defmacro split-on-keywords (words form &body body)
  "Used to handle arguments to some complex SQL operations. Arguments
are divided by keywords, which are interned with the name of the
non-keyword symbols in words, and bound to these symbols. After the
naming symbols, a ? can be used to indicate this argument group is
optional, and an * to indicate it can consist of more than one
element."
  (let ((alist (gensym)))
    `(let* ((,alist (split-on-keywords% ',words ,form))
            ,@(mapcar (lambda (word)
                        `(,(first word) (cdr (assoc ',(first word) ,alist))))
                      words))
        ,@body)))

;; Converting between symbols and SQL strings.

(defun make-sql-name (sym)
  "Convert a Lisp symbol into a name that can be an sql table, column,
or operation name."
  (cond ((eq sym '*) "*") ;; Special case
        ((and (> (length (symbol-name sym)) 1) ;; Placeholders like $2
              (char= (char (symbol-name sym) 0) #\$)
              (every #'digit-char-p (subseq (symbol-name sym) 1)))
         (symbol-name sym))
        (t (flet ((allowed-char (x)
                    (or (alphanumericp x) (eq x #\.))))
             (let ((name (string-downcase (symbol-name sym))))
               (dotimes (i (length name))
                 (unless (allowed-char (char name i))
                   (setf (char name i) #\_)))
               name)))))

(defparameter *escape-sql-names-p* nil
  "Setting this to T will make S-SQL add double quotes around
identifiers in queries, making it possible to use keywords like 'from'
or 'user' as column names \(at the cost of uglier queries).")

(defun add-quotes (name)
  "Add double quotes to around SQL identifier and around every dot in
it, for escaping table and column names."
  (loop :for dot = (position #\. name) :then (position #\. name :start (+ 2 dot))
        :while dot
        :do (setf name (format nil "~A\".\"~A"
                               (subseq name 0 dot)
                               (subseq name (1+ dot)))))
  (format nil "\"~A\"" name))

(defun to-sql-name (sym)
  "Convert a symbol to an SQL identifier, taking *escape-sql-names*
into account."
  (let ((name (make-sql-name sym)))
    (if *escape-sql-names-p*
        (add-quotes name)
        name)))

(defun from-sql-name (str)
  "Convert a string to something that might have been its original
lisp name \(does not work if this name contained non-alphanumeric
characters other than #\-)"
  (intern (map 'string (lambda (x) (if (eq x #\_) #\- x)) (string-upcase str)) (find-package :keyword)))

;; Writing out SQL type identifiers.

;; Aliases for some types that can be expressed in SQL.
(deftype smallint ()
  '(signed-byte 16))
(deftype bigint ()
  `(signed-byte 64))
(deftype numeric (&optional precision/scale scale)
  (declare (ignore precision/scale scale))
  'number)
(deftype double-precision ()
  'double-float)
(deftype bytea ()
  '(array (unsigned-byte 8)))
(deftype text ()
  'string)
(deftype varchar (length)
  (declare (ignore length))
  `string)

(deftype db-null ()
  "Type for representing NULL values. Use like \(or integer db-null)
for declaring a type to be an integer that may be null."
  '(eql :null))

;; For types integer and real, the Lisp type isn't quite the same as
;; the SQL type. Close enough though.

(defgeneric sql-type-name (lisp-type &rest args)
  (:documentation "Transform a lisp type into a string containing
something SQL understands. Default is to just use the type symbol's
name.")
  (:method ((lisp-type symbol) &rest args)
    (declare (ignore args))
    (symbol-name lisp-type))
  (:method ((lisp-type (eql 'string)) &rest args)
    (cond (args (format nil "CHAR(~A)" (car args)))
          (t "TEXT")))
  (:method ((lisp-type (eql 'varchar)) &rest args)
    (cond (args (format nil "VARCHAR(~A)" (car args)))
          (t "VARCHAR")))
  (:method ((lisp-type (eql 'numeric)) &rest args)
    (cond ((cdr args)
           (destructuring-bind (precision scale) args
             (format nil "NUMERIC(~d, ~d)" precision scale)))
          (args (format nil "NUMERIC(~d)" (car args)))
          (t "NUMERIC")))
  (:method ((lisp-type (eql 'float)) &rest args)
    (declare (ignore args))
    "REAL")
  (:method ((lisp-type (eql 'double-float)) &rest args)
    (declare (ignore args))
    "DOUBLE PRECISION")
  (:method ((lisp-type (eql 'double-precision)) &rest args)
    (declare (ignore args))
    "DOUBLE PRECISION"))

(defun to-type-name (type)
  "Turn a Lisp type expression into an SQL typename."
  (if (listp type)
      (apply 'sql-type-name type)
      (sql-type-name type)))

;; Turning lisp values into SQL strings.

(defparameter *standard-sql-strings* nil
  "Indicate whether S-SQL will use standard SQL strings (just use ''
  for #\'), or backslash-style escaping. Setting this to NIL is always
  safe, but when the server is configured to allow standard
  strings (parameter 'standard_conforming_strings' is 'on'), the noise
  in queries can be reduced by setting this to T.")

(defun sql-escape-string (string &optional prefix)
  "Escape string data so it can be used in a query."
  (let ((*print-pretty* nil))
    (with-output-to-string (*standard-output*)
      (when prefix
        (princ prefix)
        (princ #\space))
      (unless *standard-sql-strings*
        (princ #\E))
      (princ #\')
      (if *standard-sql-strings*
          (loop :for char :across string :do (princ (if (char= char #\') "''" char)))
          (loop :for char :across string
                :do (princ (case char
                             (#\' "''")
                             (#\\ "\\\\")
                             (otherwise char)))))
      (princ #\'))))

(defgeneric sql-ize (arg)
  (:documentation "Turn a lisp value into a string containing its SQL
representation. Returns an optional second value that indicates
whether the string should be escaped before being put into a query.")
  (:method ((arg string))
    (values arg t))
  (:method ((arg vector))
    (assert (typep arg '(vector (unsigned-byte 8))))
    (values (escape-bytes arg) t))
  (:method ((arg integer))
    (princ-to-string arg))
  (:method ((arg float))
    (format nil "~f" arg))
  (:method ((arg ratio))
    (format nil "~f" arg))
  (:method ((arg symbol))
    (to-sql-name arg))
  (:method ((arg (eql t)))
    "true")
  (:method ((arg (eql nil)))
    "false")
  (:method ((arg (eql :null)))
    "NULL")
  (:method ((arg simple-date:date))
    (multiple-value-bind (year month day) (simple-date:decode-date arg)
      (values (format nil "~4,'0d-~2,'0d-~2,'0d" year month day) "date")))
  (:method ((arg simple-date:timestamp))
    (multiple-value-bind (year month day hour min sec ms)
        (simple-date:decode-timestamp arg)
      (values
       (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d~@[.~3,'0d~]"
               year month day hour min sec (if (zerop ms) nil ms))
       "timestamp")))
  (:method ((arg simple-date:interval))
    (multiple-value-bind (year month day hour min sec ms)
        (simple-date:decode-interval arg)
      (flet ((not-zero (x) (if (zerop x) nil x)))
        (values
         (format nil "~@[~d years ~]~@[~d months ~]~@[~d days ~]~@[~d hours ~]~@[~d minutes ~]~@[~d seconds ~]~@[~d milliseconds~]"
                 (not-zero year) (not-zero month) (not-zero day)
                 (not-zero hour) (not-zero min) (not-zero sec) (not-zero ms))
         "interval"))))
  (:method ((arg t))
    (error "Value ~S can not be converted to an SQL literal." arg)))

(defun escape-bytes (bytes)
  "Escape an array of octets in PostgreSQL's horribly inefficient
textual format for binary data."
  (let ((*print-pretty* nil))
    (with-output-to-string (out)
      (loop :for byte :of-type fixnum :across bytes
            :do (if (or (< byte 32) (> byte 126) (= byte 39) (= byte 92))
                    (progn
                      (princ #\\ out)
                      (princ (digit-char (ldb (byte 3 6) byte) 8) out)
                      (princ (digit-char (ldb (byte 3 3) byte) 8) out)
                      (princ (digit-char (ldb (byte 3 0) byte) 8) out))
                    (princ (code-char byte) out))))))

(defun sql-ize-escaped (value)
  "Get the representation of a Lisp value so that it can be used in a
query."
  (multiple-value-bind (string escape) (sql-ize value)
    (if escape
        (sql-escape-string string (and (not (eq escape t)) escape))
        string)))

(defparameter *expand-runtime* nil)

(defun sql-expand (arg)
  "Compile-time expansion of forms into lists of stuff that evaluates
to strings \(which will form an SQL query when concatenated)."
  (cond ((and (consp arg) (keywordp (first arg)))
         (expand-sql-op (car arg) (cdr arg)))
        ((and (consp arg) (eq (first arg) 'quote))
         (list (sql-ize-escaped (second arg))))
        ((and (consp arg) *expand-runtime*)
         (expand-sql-op (intern (symbol-name (car arg)) :keyword) (cdr arg)))
        ((and (eq arg '$$) *expand-runtime*) '($$))
        (*expand-runtime*
         (list (sql-ize-escaped arg)))
        ((or (consp arg) (and (symbolp arg) (not (keywordp arg))))
         (list `(sql-ize-escaped ,arg)))
        (t (list (sql-ize-escaped arg)))))

(defun sql-expand-list (elts &optional (sep ", "))
  "Expand a list of elements, adding a separator in between them."
  (loop :for (elt . rest) :on elts
        :append (sql-expand elt)
        :if rest :collect sep))

(defun sql-expand-names (names &optional (sep ", "))
  (loop :for (name . rest) :on names
        :collect (to-sql-name name)
        :if rest :collect sep))

(defun reduce-strings (list)
  "Join adjacent strings in a list, leave other values intact."
  (let ((accum ())
        (span ""))
    (dolist (part list)
      (cond ((stringp part) (setf span (concatenate 'string span part)))
            (t (when (not (string= "" span))
                 (push span accum)
                 (setf span ""))
               (push part accum))))
    (if (not (string= "" span))
        (push span accum))
    (nreverse accum)))

(defmacro sql (form)
  "Compile form to an sql expression as far as possible."
  (let ((list (reduce-strings (sql-expand form))))
    (if (= 1 (length list))
        (car list)
        `(strcat (list ,@list)))))
  
(defun sql-compile (form)
  (let ((*expand-runtime* t))
    (car (reduce-strings (sql-expand form)))))

(defun sql-template (form)
  (let* ((*expand-runtime* t)
         (compiled (reduce-strings (sql-expand form)))
         (*print-pretty* nil))
    (lambda (&rest args)
      (with-output-to-string (*standard-output*)
        (dolist (element compiled)
          (princ (if (eq element '$$) (sql-ize-escaped (pop args)) element)))))))

;; The reader syntax.

(defun s-sql-reader (stream char min-args)
  (declare (ignore char min-args))
  (list 'sql (read stream)))

(defun enable-s-sql-syntax (&optional (char #\Q))
  "Enable a syntactic shortcut #Q\(...) for \(sql \(...)). Optionally
takes a character to use instead of #\\Q."
  (set-dispatch-macro-character #\# char 's-sql-reader))

;; Definitions of sql operators

(defgeneric expand-sql-op (op args)
  (:documentation "For overriding expansion of operators. Default is
to just place operator name in front, arguments between parentheses
behind it.")
  (:method ((op t) args)
    `(,(to-sql-name op) "(" ,@(sql-expand-list args) ")")))

(defmacro def-sql-op (name arglist &body body)
  "Macro to make defining syntax a bit more straightforward. Name
should be the keyword identifying the operator, arglist a lambda list
to apply to the arguments, and body something that produces a list of
strings and forms that evaluate to strings."
  (let ((args-name (gensym)))
    `(defmethod expand-sql-op ((op (eql ,name)) ,args-name)
       (destructuring-bind ,arglist ,args-name
         ,@body))))

(defun make-expander (arity name)
  "Generates an appropriate expander function for a given operator
with a given arity."
  (let ((with-spaces (strcat (list " " name " "))))
    (flet ((check-unary (args)
             (when (or (not args) (cdr args))
               (error "SQL operator ~A is unary." name)))
           (expand-n-ary (args)
             `("(" ,@(sql-expand-list args with-spaces) ")")))
      (ecase arity
        (:unary (lambda (args)
                  (check-unary args)
                  `("(" ,name " " ,@(sql-expand (car args)) ")")))
        (:unary-postfix (lambda (args)
                          (check-unary args)
                          `("(" ,@(sql-expand (car args)) " " ,name ")")))
        (:n-ary (lambda (args)
                  (if (cdr args)
                      (expand-n-ary args)
                      (sql-expand (car args)))))
        (:2+-ary (lambda (args)
                   (unless (cdr args)
                     (error "SQL operator ~A takes at least two arguments." name))
                   (expand-n-ary args)))
        (:n-or-unary (lambda (args)
                       (if (cdr args)
                           (expand-n-ary args)
                           `("(" ,name " " ,@(sql-expand (car args)) ")"))))))))

(defmacro register-sql-operators (arity &rest names)
  "Define simple operators. Arity is one of :unary \(like
  'not'), :unary-postfix \(the operator comes after the operand),
  :n-ary \(like '+': the operator falls away when there is only one
  operand), :2+-ary (like '=', which is meaningless for one operand),
  or :n-or-unary (like '-', where the operator is kept in the unary
  case). After the arity follow any number of operators, either just a
  keyword, in which case the downcased symbol name is used as the
  operator, or a two-element list containing a keyword and a name
  string."
  (declare (type (member :unary :unary-postfix :n-ary :n-or-unary :2+-ary) arity))
  (flet ((define-op (name)
           (let ((name (if (listp name)
                           (second name)
                           (string-downcase (symbol-name name))))
                 (symbol (if (listp name) (first name) name)))
             `(let ((expander (make-expander ,arity ,name)))
                (defmethod expand-sql-op ((op (eql ,symbol)) args)
                  (funcall expander args))))))
    `(progn ,@(mapcar #'define-op names))))

(register-sql-operators :unary :not)
(register-sql-operators :n-ary :+ :* :& :|\|| :|\|\|| :and :or :union (:union-all "union all"))
(register-sql-operators :n-or-unary :- :~)
(register-sql-operators :2+-ary  := :/ :!= :< :> :<= :>= :^ :intersect :except :~*
                                 :!~ :!~* :like :ilike)

(def-sql-op :desc (arg)
  `(,@(sql-expand arg) " DESC"))

(def-sql-op :as (form name)
  `(,@(sql-expand form) " AS " ,@(sql-expand name)))

(def-sql-op :exists (query)
  `("(EXISTS " ,@(sql-expand query) ")"))

(def-sql-op :is-null (arg)
  `("(" ,@(sql-expand arg) " IS NULL)"))

(def-sql-op :in (form set)
  `("(" ,@(sql-expand form) " IN " ,@(sql-expand set) ")"))

(def-sql-op :not-in (form set)
  `("(" ,@(sql-expand form) " NOT IN " ,@(sql-expand set) ")"))

;; This one has two interfaces. When the elements are known at
;; compile-time, they can be given as multiple arguments to the
;; operator. When they are not, a single argument that evaulates to a
;; list should be used.
(def-sql-op :set (&rest elements)
  (if (not elements)
      '("(NULL)")
      (let ((expanded (sql-expand-list elements)))
        ;; Ugly way to check if everything was expanded
        (if (stringp (car expanded))
            `("(" ,@expanded ")")
            `("(" (let ((elements ,(car elements)))
                    (if (null elements) "NULL"
                        (implode ", " (mapcar 'sql-ize-escaped elements)))) ")")))))

(def-sql-op :dot (&rest args)
  (sql-expand-list args "."))

(def-sql-op :type (value type)
  `(,@(sql-expand value) "::" ,(to-type-name type)))

(def-sql-op :raw (sql)
  (list sql))

;; Selecting and manipulating

(defun expand-joins (args)
  "Helper for the select operator. Turns the part following :from into
the proper SQL syntax for joining tables."
  (labels ((is-join (x) (member x '(:left-join :right-join :inner-join :cross-join))))
    (when (null args)
      (error "Empty :from clause in select"))
    (when (is-join (car args))
      (error ":from clause starts with a join: ~A" args))
    (let ((rest args))
      (loop :while rest
            :for first = t :then nil
            :append (cond ((is-join (car rest))
                           (destructuring-bind (join name on clause &rest left) rest
                              (setf rest left)
                              (unless (and (eq on :on) clause)
                                (error "Incorrect join form in select."))
                              `(" " ,(ecase join
                                        (:left-join "LEFT") (:right-join "RIGHT")
                                        (:inner-join "INNER") (:cross-join "CROSS"))
                                " JOIN " ,@(sql-expand name)
                                " ON " ,@(sql-expand clause))))
                          (t (prog1 `(,@(if first () '(", ")) ,@(sql-expand (car rest)))
                               (setf rest (cdr rest)))))))))

(def-sql-op :select (&rest args)
  (split-on-keywords ((vars *) (distinct - ?) (distinct-on * ?) (from * ?) (where ?) (group-by * ?) (having ?)) (cons :vars args)
    `("(SELECT "
      ,@(if distinct '("DISTINCT "))
      ,@(if distinct-on `("DISTINCT ON (" ,@(sql-expand-list distinct-on) ") "))
      ,@(sql-expand-list vars)
      ,@(if from (cons " FROM " (expand-joins from)))
      ,@(if where (cons " WHERE " (sql-expand (car where))))
      ,@(if group-by (cons " GROUP BY " (sql-expand-list group-by)))
      ,@(if having (cons " HAVING " (sql-expand (car having))))
      ")")))

(def-sql-op :limit (form amount &optional offset)
  `("(" ,@(sql-expand form) " LIMIT " ,@(sql-expand amount) ,@(if offset (cons " OFFSET " (sql-expand offset)) ()) ")"))

(def-sql-op :order-by (form &rest fields)
  `("(" ,@(sql-expand form) " ORDER BY " ,@(sql-expand-list fields) ")"))

(defun escape-sql-expression (expr)
  "Try to escape an expression at compile-time, if not possible, delay
to runtime. Used to create stored procedures."
  (let ((expanded (append (sql-expand expr) '(";"))))
    (if (every 'stringp expanded)
        (sql-escape-string (apply 'concatenate 'string expanded))
        `(sql-escape-string (concatenate 'string ,@(reduce-strings expanded))))))

(def-sql-op :function (name (&rest args) return-type stability body)
  (assert (member stability '(:immutable :stable :volatile)))
  `("CREATE OR REPLACE FUNCTION " ,@(sql-expand name) " (" ,(implode ", " (mapcar 'to-type-name args))
    ") RETURNS " ,(to-type-name return-type) " LANGUAGE SQL " ,(symbol-name stability) " AS " ,(escape-sql-expression body)))

(def-sql-op :insert-into (table insert-method &rest rest)
  (cond ((eq insert-method :set)
         (if (oddp (length rest))
             (error "Invalid amount of :set arguments passed to insert-into sql operator")
             `("INSERT INTO " ,@(sql-expand table) " (" 
               ,@(sql-expand-list (loop :for (field value) :on rest :by #'cddr
                                        :collect field)) ") VALUES ("
               ,@(sql-expand-list (loop :for (field value) :on rest :by #'cddr
                                        :collect value)) ")")))
        ((and (not rest) (consp insert-method) (keywordp (first insert-method)))
         `("INSERT INTO " ,@(sql-expand table) " " ,@(sql-expand insert-method)))
        (t
         (error "No :set arguments or select operator passed to insert-into sql operator"))))

(def-sql-op :update (table &rest args)
  (split-on-keywords ((set *) (where ?)) args
    (when (oddp (length set))
      (error "Invalid amount of :set arguments passed to update sql operator"))
    `("UPDATE " ,@(sql-expand table) " SET "
      ,@(loop :for (field value) :on set :by #'cddr
              :for first = t :then nil
              :append `(,@(if first () '(", ")) ,@(sql-expand field) " = " ,@(sql-expand value)))
      ,@(if where (cons " WHERE " (sql-expand (car where))) ()))))

(def-sql-op :delete-from (table &key where)
  `("DELETE FROM " ,@(sql-expand table) ,@(if where (cons " WHERE " (sql-expand where)) ())))

;; Data definition

(def-sql-op :create-table (name (&rest columns) &rest options)
  (labels ((dissect-type (type)
             (if (and (consp type) (eq (car type) 'or) (member 'db-null type) (= (length type) 3))
                 (if (eq (second type) 'db-null)
                     (values (third type) t)
                     (values (second type) t))
                 (values type nil)))
           (reference-action (action)
             (case action
               (:restrict "RESTRICT")
               (:set-null "SET NULL")
               (:set-default "SET DEFAULT")
               (:cascade "CASCADE")
               (:no-action "NO ACTION")
               (t (error "Unsupported action for foreign key: ~A" action))))
           (build-foreign (target on-delete on-update)
             `(" REFERENCES "
               ,@(if (consp target)
                     `(,(to-sql-name (car target)) "(" ,@(sql-expand-names (cdr target)) ")")
                     `(,(to-sql-name target)))
               " ON DELETE " ,(reference-action on-delete)
               " ON UPDATE " ,(reference-action on-update)))
           (expand-column (column-name args)
             `(,(to-sql-name column-name) " "
               ,@(let ((type (or (getf args :type)
                                 (error "No type specified for column ~A." column-name))))
                   (multiple-value-bind (type null) (dissect-type type)
                     `(,(to-type-name type) ,@(when (not null) '(" NOT NULL")))))
               ,@(loop :for (option value) :on args :by #'cddr
                       :append (case option
                                 (:default `(" DEFAULT " ,@(sql-expand value)))
                                 (:primary-key (when value `(" PRIMARY KEY")))
                                 (:unique (when value `(" UNIQUE")))
                                 (:check `(" CHECK " ,@(sql-expand value)))
                                 (:references
                                  (destructuring-bind (target &optional (on-delete :restrict) (on-update :restrict)) value
                                    (build-foreign target on-delete on-update)))
                                 (:type ())
                                 (t (error "Unknown column option: ~A." option))))))
           (expand-option (option args)
             (case option
               (:check `("CHECK " ,@(sql-expand (car args))))
               (:primary-key `("PRIMARY KEY (" ,@(sql-expand-names args) ")"))
               (:unique `("UNIQUE (" ,@(sql-expand-names args) ")"))
               (:foreign-key 
                (destructuring-bind (columns target &optional (on-delete :restrict) (on-update :restrict)) args
                  `("FOREIGN KEY (" ,@(sql-expand-names columns) ")"
                    ,@(build-foreign target on-delete on-update)))))))
    (when (null columns)
      (error "No columns defined for table ~A." name))
    `("CREATE TABLE " ,(to-sql-name name) " ("
      ,@(loop :for ((column-name . args) . rest) :on columns
              :append (expand-column column-name args)
              :if rest :collect ", ")
      ,@(loop :for ((option . args) . rest) :on options
              :collect ", "
              :append (expand-option option args))
      ")")))

(def-sql-op :drop-table (name)
  `("DROP TABLE " ,@(sql-expand name)))

(defun expand-create-index (name args)
  (split-on-keywords ((on) (using ?) (fields *)) args
    `(,@(sql-expand name) " ON " ,@(sql-expand (first on))
      ,@(when using `(" USING " ,(symbol-name (first using))))
      " (" ,@(sql-expand-list fields) ")")))

(def-sql-op :create-index (name &rest args)
  (cons "CREATE INDEX " (expand-create-index name args)))

(def-sql-op :create-unique-index (name &rest args)
  (cons "CREATE UNIQUE INDEX " (expand-create-index name args)))

(def-sql-op :drop-index (name)
  `("DROP INDEX " ,@(sql-expand name)))

(def-sql-op :create-sequence (name &key increment min-value max-value start cache cycle)
  `("CREATE SEQUENCE " ,@(sql-expand name)
    ,@(when increment `(" INCREMENT " ,@(sql-expand increment)))
    ,@(when min-value `(" MINVALUE " ,@(sql-expand min-value)))
    ,@(when max-value `(" MAXVALUE " ,@(sql-expand max-value)))
    ,@(when start `(" START " ,@(sql-expand start)))
    ,@(when cache `(" CACHE " ,@(sql-expand cache)))
    ,@(when cycle `(" CYCLE"))))

(def-sql-op :drop-sequence (name)
  `("DROP SEQUENCE " ,@(sql-expand name)))

;;; Copyright (c) 2006 Marijn Haverbeke & Streamtech
;;;
;;; This software is provided 'as-is', without any express or implied
;;; warranty. In no event will the authors be held liable for any
;;; damages arising from the use of this software.
;;;
;;; Permission is granted to anyone to use this software for any
;;; purpose, including commercial applications, and to alter it and
;;; redistribute it freely, subject to the following restrictions:
;;;
;;; 1. The origin of this software must not be misrepresented; you must
;;;    not claim that you wrote the original software. If you use this
;;;    software in a product, an acknowledgment in the product
;;;    documentation would be appreciated but is not required.
;;;
;;; 2. Altered source versions must be plainly marked as such, and must
;;;    not be misrepresented as being the original software.
;;;
;;; 3. This notice may not be removed or altered from any source
;;;    distribution.
