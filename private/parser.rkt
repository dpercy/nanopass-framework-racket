#lang racket/base
;;; Copyright (c) 2000-2013 Dipanwita Sarkar, Andrew W. Keep, R. Kent Dybvig, Oscar Waddell
;;; See the accompanying file Copyright for details

(provide define-parser trace-define-parser)

(require "nano-syntax-dispatch.rkt"
         racket/trace
         (only-in "helpers.rkt" define-who np-parse-fail-token)
         (for-syntax racket/syntax
                     syntax/stx
                     racket/base
                     "helpers.rkt"
                     "records.rkt"
                     "syntaxconvert.rkt"))

(define-syntax parse-or
  (syntax-rules (on-error)
    [(_ (on-error ?err0)) ?err0]
    [(_ (on-error ?err0) ?e0 . ?e1)
     (let ([t0 ?e0])
       (if (eq? t0 np-parse-fail-token)
           (parse-or (on-error ?err0) . ?e1)
           t0))]))

(define-syntax define-parser
  (syntax-rules ()
    [(_ . rest) (x-define-parser . rest)]))

(define-syntax trace-define-parser
  (syntax-rules ()
    [(_ . rest) (x-define-parser trace . rest)]))

(define-syntax x-define-parser
  (lambda (x)
    (define ntspec-parsers (make-hasheq))
    (define make-parse-proc
      (lambda (desc tspecs ntspecs ntspec lang-name)
        (define parse-field
          (lambda (m level maybe?)
            (cond
              [(meta-name->tspec m tspecs) m]
              [(meta-name->ntspec m ntspecs) =>
               (lambda (spec)
                 (with-syntax ([proc-name (hash-ref ntspec-parsers spec #f)])
                   (let f ([level level] [x m])
                     (if (= level 0)
                         (if maybe? #`(and #,x (proc-name #,x #t))  #`(proc-name #,x #t))
                         #`(map (lambda (x) #,(f (- level 1) #'x)) #,x)))))]
              [else (raise-syntax-error 'parser "unrecognized meta variable"
                      (language-name desc) m)])))

        (define-who make-term-clause
          (lambda (alt)
            (with-syntax ([term-pred?
                           (cond
                             [(meta-name->tspec (alt-syn alt) tspecs) =>
                              (lambda (tspec) (tspec-pred tspec))]
                             [else (error who "expected to find matching tspec ~s" alt)])])
              #'[(term-pred? s-exp) s-exp])))

        (define make-nonterm-clause
          (lambda (alt)
            (let ([spec (meta-name->ntspec (alt-syn alt) ntspecs)])
              (unless spec
                (raise-syntax-error 'parser "unrecognized meta variable"
                  (language-name desc) (alt-syn alt)))
              (with-syntax ([proc-name (hash-ref ntspec-parsers spec #f)])
                #`(proc-name s-exp #f)))))

        (define make-pair-clause
          (lambda (alt)
            (let ([field-pats (pair-alt-pattern alt)])
              (with-syntax ([maker (pair-alt-maker alt)]
                            [(field-var ...) (pair-alt-field-names alt)])
                (with-syntax ([(parsed-field ...)
                               (map parse-field
                                 (stx->list #'(field-var ...))
                                 (pair-alt-field-levels alt)
                                 (pair-alt-field-maybes alt))]
                              [(msg ...)
                               (map (lambda (x) #f)
                                 (stx->list #'(field-var ...)))])
                  #`(#,(if (pair-alt-implicit? alt)
                           #`(nano-syntax-dispatch
                               s-exp '#,(datum->syntax #'lang-name field-pats))
                           #`(and (eq? '#,(stx-car (alt-syn alt)) (car s-exp))
                                  (nano-syntax-dispatch
                                    (cdr s-exp)
                                    '#,(datum->syntax #'lang-name field-pats))))
                      => (lambda (ls)
                           (apply
                             (lambda (field-var ...)
                               (let ([field-var parsed-field] ...)
                                 (maker who field-var ... msg ...))) ls))))))))

        (partition-syn (ntspec-alts ntspec)
          ([term-alt* terminal-alt?]
           [nonterm-alt* nonterminal-alt?]
           [pair-imp-alt* pair-alt-implicit?]
           [pair-alt* otherwise])
          (partition-syn nonterm-alt*
            ([nonterm-imp-alt* (lambda (alt) (has-implicit-alt? (nonterminal-alt-ntspec alt (language-ntspecs desc)) (language-ntspecs desc)))]
             [nonterm-nonimp-alt* otherwise])
            #`(lambda (s-exp at-top-parse?)
                (parse-or
                  (on-error
                    (if at-top-parse?
                        (error who "invalid syntax ~s" s-exp)
                        np-parse-fail-token))
                  #,@(map make-nonterm-clause nonterm-nonimp-alt*)
                  (if (pair? s-exp)
                      (cond
                        #,@(map make-pair-clause pair-alt*)
                        #,@(map make-pair-clause pair-imp-alt*)
                        [else np-parse-fail-token])
                      (cond
                        #,@(map make-term-clause term-alt*)
                        [else np-parse-fail-token]))
                  #,@(map make-nonterm-clause nonterm-imp-alt*)))))))

    (define make-parser
      (lambda (parser-name lang trace?)
        (let ([desc-pair (lookup-language 'define-parser "unrecognized language name" lang)])
          (unless desc-pair
            (error (if trace? 'trace-define-syntax 'define-syntax)
              "invalid language identifier ~a" lang))
          (let* ([desc (car desc-pair)]
                 [ntname (language-entry-ntspec desc)]
                 [lang-name (language-name desc)]
                 [ntspecs (language-ntspecs desc)]
                 [tspecs (language-tspecs desc)])
            (when (null? ntspecs)
              (error 'define-parser "unable to generate parser for language without non-terminals"))
            (with-syntax ([(parse-name ...)
                           (map (lambda (ntspec)
                                  (let ([pred (format-id lang-name "parse-~a" (ntspec-name ntspec))])
                                    (hash-set! ntspec-parsers ntspec pred)
                                    pred))
                                ntspecs)])
              (with-syntax ([(parse-proc ...)
                             (map (lambda (ntspec)
                                    (make-parse-proc desc tspecs ntspecs ntspec lang-name))
                                  ntspecs)])
                (with-syntax ([entry-proc-name (format-id lang-name "parse-~a" ntname)]
                              [parser-name parser-name])
                  (with-syntax ([(lam-exp ...) (if trace? #'(trace-lambda #:name parser-name) #'(lambda))]
                                [def (if trace? #'trace-define #'define)])
                    #'(define-who parser-name
                        (lam-exp ... (s-exp)
                          (def parse-name parse-proc)
                          ...
                          (entry-proc-name s-exp #t)))))))))))
    (syntax-case x (trace)
      [(_ parser-name lang)
       (and (identifier? #'parser-name) (identifier? #'lang))
       (make-parser #'parser-name #'lang #f)]
      [(_ trace parser-name lang)
       (and (identifier? #'parser-name) (identifier? #'lang))
       (make-parser #'parser-name #'lang #t)])))
