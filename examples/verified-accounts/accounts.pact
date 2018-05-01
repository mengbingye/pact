;; accounts module, admin keyset, and table
; (load "examples/verified-accounts/accounts.repl")

(enforce-pact-version "2.3")

(define-keyset 'accounts-admin-keyset
  (read-keyset "accounts-admin-keyset"))

(module accounts 'accounts-admin-keyset
  "Accounts module demonstrating row-level keysets, private pacts, and escrow. \
\  Version: 0.2                                                                \
\  Author: Stuart Popejoy"

  (defschema account
    "Row type for accounts table."
     balance:decimal
     amount:decimal
     ccy:string
     auth:string     ;; AUTH_KEYSET for keysets, pact id for pacts
     )

  (deftable accounts:{account}
    "Main table for accounts module.")

  (defconst AUTH_KEYSET 'K
    "Indicates keyset-governed account")

  (defconst PACT_REF "ref")

  (defun create-account (address:string ccy)
    (insert accounts address
      { "balance": 0.0
      , "amount": 0.0
      , "ccy": ccy
      , "auth": AUTH_KEYSET
      }
    ))

  ; TODO: defproperty?
  ; (@property conserves-mass)
  (defun transfer (src:string dest:decimal amount:decimal)
    "transfer AMOUNT from SRC to DEST"
    (debit src amount))
    ; (credit dest amount))

  (defun read-account-user (id)
    "Read data for account ID"
    (with-read accounts id
              { "balance":= b
              , "ccy":= c
              , "auth" := auth }
      ; TODO: we can't handle this object yet
      ; { "balance": b, "ccy": c }
      b
      ))

  (@property
    (when
        (not (authorized-by 'accounts-admin-keyset))
        abort))
  (defun read-account-admin (id)
    "Read data for account ID, admin version"
    (enforce-keyset 'accounts-admin-keyset)
    (read accounts id ['balance 'ccy 'amount]))

  (defun check-balance (balance:decimal amount:decimal)
    (enforce (<= amount balance) "Insufficient funds"))

  (defun fund-account (address amount)
    (enforce-keyset 'accounts-admin-keyset)
    (update accounts address
            { "balance": amount
            , "amount": amount }
      ))

  ; ; alternately
  ; (@property
  ;   (with-read 'delta accounts acct
  ;     { "balance" := amount }))
  (defun debit (acct amount)
    "Debit AMOUNT from ACCT balance"
    (with-read accounts acct
              { "balance":= balance
              , "auth" := auth
              }
      ; (check-balance balance amount)
      (update accounts acct
                { "balance": (- balance amount)
                , "amount": (- amount)
                }
          )))

 (defun credit (acct amount)
   "Credit AMOUNT to ACCT balance"
   (with-read accounts acct
              { "balance":= balance }
     (update accounts acct
            { "balance": (+ balance amount)
            , "amount": amount
            }
      )))
)

(create-table accounts)
;done