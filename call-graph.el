;;; call-graph.el --- Library to generate call graph for cpp functions  -*- lexical-binding: t; -*-

;; Copyright (C) 2018 Huming Chen

;; Author: Huming Chen <chenhuming@gmail.com>
;; Maintainer: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/call-graph
;; Version: 0.0.3
;; Keywords: programming, convenience
;; Created: 2018-01-07
;; Package-Requires: ((emacs "25.1") (hierarchy "0.7.0") (tree-mode "1.0.0") (queue "0.2"))

;; This file is not part of GNU Emacs.

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

;; Library to generate call graph for cpp functions.

;;; Install:

;; Put this file into load-path directory, and byte compile it if
;; desired. And put the following expression into your ~/.emacs.
;;
;;     (require 'call-graph)
;;     (global-set-key (kbd "C-c g") 'call-graph)
;;
;;; Usage:

;; "C-c g" => (call-graph) => buffer <*call-graph*> will be generated

;;; Code:

(require 'queue)
(require 'hierarchy)
(require 'tree-mode)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Definition
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgroup call-graph nil
  "Customization support for the `call-graph'."
  :version "0.0.3"
  :group 'applications)

(defcustom call-graph-max-depth 2
  "The maximum depth of call graph."
  :type 'integer
  :group 'call-graph)

(defcustom call-graph-filters nil
  "The filters used by `call-graph' when searching caller."
  :type 'list
  :group 'call-graph)

(defconst call-graph--key-to-depth "*current-depth*"
  "The key to get current depth of call graph.")

(defconst call-graph--key-to-caller-location "*caller-location*"
  "The key to get caller location.")

(defvar call-graph--hierarchy nil
  "The hierarchy used to display call graph.")
(make-variable-buffer-local 'call-graph--hierarchy)

;; use hash-table as the building blocks for tree
(defun call-graph--make-node ()
  "Serve as tree node."
  (make-hash-table :test 'equal))

(defvar call-graph--internal-cache (call-graph--make-node)
  "The internal cache of call graph.")

(defcustom call-graph-termination-list '("main")
  "Call-graph stops when seeing symbols from this list."
  :type 'list
  :group 'call-graph)

(defcustom call-graph-unique-buffer t
  "Non-nil means only one buffer will be used for `call-graph'."
  :type 'boolean
  :group 'call-graph)

(defcustom call-graph-display-file-at-point t
  "Non-nil means display file in another window while moving from one field to another in `call-graph'."
  :type 'boolean
  :group 'call-graph)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun call-graph--get-buffer ()
  "Generate ‘*call-graph*’ buffer."
  (let ((buffer-name "*call-graph*"))
    (if call-graph-unique-buffer
        (get-buffer-create buffer-name)
      (generate-new-buffer buffer-name))))

(defun call-graph--built-in-keys-p (key)
  "Return non-nil if KEY is not one of built-in keys."
  (member key (list
               call-graph--key-to-depth
               call-graph--key-to-caller-location)))

(defun call-graph--find-callers-in-cache (func)
  "Given a function FUNC, search internal cache to find all callers of this function."
  (when-let ((sub-node (map-elt call-graph--internal-cache func))
             (has-callers
              (not
               (map-empty-p
                (map-remove (lambda (key _) (call-graph--built-in-keys-p key)) sub-node)))))
    sub-node))

(defun call-graph--find-caller (reference)
  "Given a REFERENCE, return the caller of this reference."
  (when-let ((tmp-val (split-string reference ":"))
             (file-name (seq-elt tmp-val 0))
             (line-nb-str (seq-elt tmp-val 1))
             (line-nb (string-to-number line-nb-str))
             (is-valid-file (file-exists-p file-name))
             (is-valid-nb (integerp line-nb)))
    (let ((location (concat file-name ":" line-nb-str))
          caller)
      (with-temp-buffer
        (insert-file-contents-literally file-name)
        ;; TODO: leave only hooks on which 'which-function-mode depends
        ;; (set (make-local-variable 'c++-mode-hook) nil)
        (c++-mode)
        (which-function-mode t)
        (forward-line line-nb)
        (setq caller (which-function)))
      (when (and caller (setq tmp-val (split-string caller "::")))
        (if (> (seq-length tmp-val) 1)
            (cons (seq-elt tmp-val 1) location)
          (cons (seq-elt tmp-val 0) location))))))

(defun call-graph--find-references (func)
  "Given a function FUNC, return all references of it."
  (let ((command
         (format "global -a --result=grep -r %s | grep -E \"\\.(cpp|cc):\""
                 (shell-quote-argument (symbol-name func))))
        (filter-separator " | ")
        command-filter command-out-put)
    (when (and (> (length call-graph-filters) 0)
               (setq command-filter
                     (mapconcat #'identity (delq nil call-graph-filters) filter-separator))
               (not (string= command-filter filter-separator)))
      (setq command (concat command filter-separator command-filter)))
    (when (setq command-out-put (shell-command-to-string command))
      (split-string command-out-put "\n" t))))

(defun call-graph--walk-tree-in-bfs-order (item node func)
  "Wallk tree in BFS order, for each (ITEM . NODE) apply FUNC.
ITEM is parent of NODE, NODE should be a hash-table."
  (let ((queue (queue-create))
        queue-elt current-item current-node)
    (queue-enqueue queue (cons item node))
    (while (not (queue-empty queue))
      (setq queue-elt (queue-dequeue queue)
            current-item (car queue-elt)
            current-node (cdr queue-elt))
      (funcall func current-item current-node)
      (seq-doseq (map-pair (map-pairs current-node))
        (when (hash-table-p (cdr map-pair))
          (queue-enqueue queue map-pair))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Function
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun call-graph--create (item root)
  "Construct `call-graph' tree.
ITEM is parent of root, ROOT should be a hash-table."
  (when (and item root)
    (let ((caller-visited call-graph-termination-list))
      (push (symbol-name item) caller-visited)
      (map-put root call-graph--key-to-depth 0)
      ;; (map-put root call-graph--key-to-caller-location location)
      (map-put call-graph--internal-cache (symbol-name item) root)
      (catch 'exceed-max-depth
        (call-graph--walk-tree-in-bfs-order
         item root
         (lambda (parent node)
           (when (hash-table-p node)
             (let ((depth (map-elt node call-graph--key-to-depth 0))
                   location sub-node)
               (when (> depth call-graph-max-depth) (throw 'exceed-max-depth t))
               (seq-doseq (reference (call-graph--find-references parent))
                 (when-let ((is-vallid reference)
                            (caller (call-graph--find-caller reference))
                            (location (cdr caller))
                            (caller (car caller))
                            (is-new (not (member caller caller-visited))))
                   (message caller)
                   (push caller caller-visited)
                   (setq sub-node (call-graph--make-node))
                   (map-put sub-node call-graph--key-to-depth (1+ depth))
                   (map-put sub-node call-graph--key-to-caller-location location)
                   ;; save to cache for fast data retrival
                   (map-put call-graph--internal-cache caller sub-node)
                   (map-put node (intern caller) sub-node)))))))))))

(defun call-graph--create2 (item root)
  "Construct `call-graph' tree.
ITEM is parent of root, ROOT should be a hash-table."
  (when (and item root)
    (let ((caller-visited call-graph-termination-list))
      (push (symbol-name item) caller-visited)
      (if (call-graph--find-callers-in-cache item)
          (setq root (call-graph--find-callers-in-cache item))
        (map-put call-graph--internal-cache item root)
        (map-put root call-graph--key-to-depth 0)
        ;; (map-put root call-graph--key-to-caller-location location)
        )
      (catch 'exceed-max-depth
        (call-graph--walk-tree-in-bfs-order
         item root
         (lambda (parent node)
           (when (hash-table-p node)
             (let ((depth (map-elt node call-graph--key-to-depth 0)))
               (when (> depth call-graph-max-depth) (throw 'exceed-max-depth t))
               (if-let ((caller-map (call-graph--find-callers-in-cache parent))
                        (caller-pairs (map-pairs caller-map))
                        (not-empty (not (map-empty-p caller-pairs))))
                   ;; Found in internal-cache
                   (seq-doseq (caller-pair caller-pairs)
                     (when-let ((caller (car caller-pair))
                                (is-valid (not (call-graph--built-in-keys-p caller)))
                                (sub-node (cdr caller-pair))
                                (is-new (not (member caller caller-visited))))
                       (message (symbol-name caller))
                       (map-put sub-node call-graph--key-to-depth (1+ depth))))
                 ;; Not found in internal-cache
                 (seq-doseq (reference (call-graph--find-references parent))
                   (when-let ((is-vallid reference)
                              (caller-pair (call-graph--find-caller reference))
                              (location (cdr caller-pair))
                              (caller (car caller-pair))
                              (sub-node (call-graph--make-node))
                              (is-new (not (member caller caller-visited))))
                     (message caller)
                     (push caller caller-visited)
                     (map-put call-graph--internal-cache (intern caller) sub-node)
                     (map-put node (intern caller) sub-node)
                     (map-put sub-node call-graph--key-to-depth (1+ depth))
                     (map-put sub-node call-graph--key-to-caller-location location))))))))))))

(defun call-graph--display (item root)
  "Prepare data for display.
ITEM is parent of root, ROOT should be a hash-table."
  (let ((first-time t) (log (list)))
    (call-graph--walk-tree-in-bfs-order
     item root
     (lambda (parent node)
       (when (hash-table-p node)
         (seq-doseq (child (map-keys node))
           (when first-time (setq first-time nil)
                 (hierarchy--add-relation call-graph--hierarchy parent nil 'identity))
           (unless (call-graph--built-in-keys-p child)
             ;; ignore the "...only have one parent..." error
             (ignore-errors
               (hierarchy--add-relation call-graph--hierarchy child parent 'identity))
             (push
              (concat "insert childe " (symbol-name child)
                      " under parent " (symbol-name parent)) log))))))
    (call-graph--hierarchy-display)
    (seq-doseq (rec (reverse log)) (message rec))))

(defun call-graph--hierarchy-display ()
  "Display call graph with hierarchy."
  (switch-to-buffer-other-window
   (hierarchy-tree-display
    call-graph--hierarchy
    (lambda (tree-item _)
      (let* ((caller (symbol-name tree-item))
             (location (map-elt (map-elt call-graph--internal-cache tree-item)
                                call-graph--key-to-caller-location)))
        ;; use propertize to avoid this error => Attempt to modify read-only object
        ;; @see https://stackoverflow.com/questions/24565068/emacs-text-is-read-only
        (insert (propertize caller 'caller-location location))))
    (call-graph--get-buffer)))
  (call-graph-mode)
  (call-graph-widget-expand-all))

;;;###autoload
(defun call-graph ()
  "Generate a function `call-graph' for the function at point."
  (interactive)
  (save-excursion
    (when-let ((target (symbol-at-point))
               (root (call-graph--make-node)))
      (setq call-graph--hierarchy (hierarchy-new))
      (call-graph--create2 target root)
      (call-graph--display target root))))

(defun call-graph-quit ()
  "Quit `call-graph'."
  (interactive)
  (kill-this-buffer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Widget operation
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun call-graph-widget-expand-all ()
  "Iterate all widgets in buffer and expand em."
  (interactive)
  (tree-mode-expand-level 0))

(defun call-graph-widget-collapse-all (&optional level)
  "Iterate all widgets in buffer and close em at LEVEL."
  (interactive)
  (goto-char (point-min))
  (tree-mode-expand-level (or level 1)))

(defun call-graph-visit-file-at-point ()
  "Visit occurrence on the current line."
  (when-let ((location (get-text-property (point) 'caller-location))
             (tmp-val (split-string location ":"))
             (file-name (seq-elt tmp-val 0))
             (line-nb-str (seq-elt tmp-val 1))
             (line-nb (string-to-number line-nb-str))
             (is-valid-file (file-exists-p file-name))
             (is-valid-nb (integerp line-nb)))
    (find-file-read-only-other-window file-name)
    (with-no-warnings (goto-line line-nb))))

(defun call-graph-goto-file-at-point ()
  "Go to the occurrence on the current line."
  (interactive)
  (save-excursion
    (when (get-char-property (point) 'button)
      (forward-char 4))
    (call-graph-visit-file-at-point)))

(defun call-graph-display-file-at-point ()
  "Display in another window the occurrence the current line describes."
  (interactive)
  (save-selected-window
    (call-graph-goto-file-at-point)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mode
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar call-graph-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "e") 'call-graph-widget-expand-all)
    (define-key map (kbd "c") 'call-graph-widget-collapse-all)
    (define-key map (kbd "p") 'widget-backward)
    (define-key map (kbd "n") 'widget-forward)
    (define-key map (kbd "q") 'call-graph-quit)
    (define-key map (kbd "d") 'call-graph-display-file-at-point)
    (define-key map (kbd "o") 'call-graph-goto-file-at-point)
    (define-key map (kbd "<RET>") 'call-graph-goto-file-at-point)
    (define-key map (kbd "g")  nil) ; nothing to revert
    map)
  "Keymap for `call-graph' major mode.")

;;;###autoload
(define-derived-mode call-graph-mode special-mode "call-graph"
  "Major mode for viewing function's `call graph'.
\\{call-graph-mode-map}"
  :group 'call-graph
  (buffer-disable-undo)
  (setq truncate-lines t
        buffer-read-only t
        show-trailing-whitespace nil)
  (setq-local line-move-visual t)
  (hack-dir-local-variables-non-file-buffer)
  (make-local-variable 'text-property-default-nonsticky)
  (push (cons 'keymap t) text-property-default-nonsticky)
  (when call-graph-display-file-at-point
    (add-hook 'widget-move-hook (lambda () (call-graph-display-file-at-point))))
  (run-mode-hooks))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Tests
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (global-set-key (kbd "C-c g") 'call-graph)


(provide 'call-graph)
;;; call-graph.el ends here
