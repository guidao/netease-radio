;;; netease-radio.el --- NetEase Cloud Music player -*- lexical-binding: t; -*-

;; Author: guidao
;; URL: https://github.com/guidao/netease-radio
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; netease-radio is a small Emacs audio player for NetEase Cloud Music.
;; It uses NetEase's unauthenticated search endpoint for discovery, yt-dlp
;; for URL metadata imports, and mpv for playback.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)

(defconst netease-radio--state-version 1
  "Current durable state file version.")

(defvar netease-radio--helper-directory
  (when load-file-name
    (expand-file-name "helper" (file-name-directory load-file-name)))
  "Directory containing the netease-radio helper Python scripts.")

(defgroup netease-radio nil
  "Play NetEase Cloud Music audio from Emacs."
  :group 'multimedia)

(defface netease-radio-section-title
  '((t (:inherit bold)))
  "Face for netease-radio source section headings."
  :group 'netease-radio)

(defface netease-radio-track-title
  '((t (:inherit link :underline nil)))
  "Face for clickable netease-radio track titles."
  :group 'netease-radio)

(defface netease-radio-current-track
  '((t (:inherit bold)))
  "Face for the current netease-radio track row."
  :group 'netease-radio)

(defface netease-radio-header-logo
  '((t (:inherit bold)))
  "Face for the netease-radio browser logo."
  :group 'netease-radio)

(defface netease-radio-header-active
  '((t (:inherit mode-line-emphasis :underline t :weight bold)))
  "Face for active netease-radio header items."
  :group 'netease-radio)

(defface netease-radio-header-inactive
  '((t (:inherit shadow)))
  "Face for inactive netease-radio header items."
  :group 'netease-radio)

(defface netease-radio-now-playing-title
  '((t (:inherit bold :height 1.1)))
  "Face for the now-playing track title."
  :group 'netease-radio)

(defface netease-radio-child-frame-border
  '((t (:background "gray40")))
  "Face for the now-playing child-frame border."
  :group 'netease-radio)

(defface netease-radio-home-header
  '((t (:inherit bold :height 1.3)))
  "Face for the Home view header."
  :group 'netease-radio)

(defface netease-radio-home-playlist-title
  '((t (:inherit bold :height 1.1)))
  "Face for Home view playlist titles."
  :group 'netease-radio)

(defcustom netease-radio-mpv-program "mpv"
  "Program name or path used to run mpv."
  :type 'string
  :group 'netease-radio)

(defcustom netease-radio-yt-dlp-program "yt-dlp"
  "Program name or path used to run yt-dlp."
  :type 'string
  :group 'netease-radio)

(defcustom netease-radio-yt-dlp-cookies nil
  "Path to a cookies.txt file for NetEase Cloud Music authentication.
Use a browser extension (e.g. \='Get cookies.txt\=') to export cookies
from music.163.com after logging in with your VIP account.

When set, cookies are passed to --cookies for yt-dlp and to
--ytdl-raw-options=cookies=... for mpv."
  :type '(choice (const :tag "No cookies" nil)
                 (file :tag "cookies.txt"))
  :group 'netease-radio)

(defcustom netease-radio-mpv-extra-args nil
  "Extra arguments passed to mpv before the media URL."
  :type '(repeat string)
  :group 'netease-radio)

(defcustom netease-radio-mpv-ytdl-format "bestaudio/best"
  "Default mpv ytdl format used when playing NetEase URLs.
Set nil to let mpv choose its own ytdl format."
  :type '(choice (const :tag "mpv default" nil)
                 string)
  :group 'netease-radio)

(defcustom netease-radio-search-limit 20
  "Maximum number of tracks returned by `netease-radio-search'."
  :type 'natnum
  :group 'netease-radio)

(defcustom netease-radio-data-directory
  (expand-file-name "~/.netease-radio/")
  "Directory used for netease-radio runtime data."
  :type 'directory
  :group 'netease-radio)

(defcustom netease-radio-state-file
  (expand-file-name "state.eld" netease-radio-data-directory)
  "File used to persist netease-radio sources and last track."
  :type 'file
  :group 'netease-radio)

(defcustom netease-radio-api-search-url
  "https://music.163.com/api/search/get/web"
  "NetEase Cloud Music search endpoint used by `netease-radio-search'."
  :type 'string
  :group 'netease-radio)

(defcustom netease-radio-api-discover-playlists-url
  "https://music.163.com/api/personalized/playlist"
  "NetEase Cloud Music recommended playlist endpoint."
  :type 'string
  :group 'netease-radio)

(defcustom netease-radio-api-toplist-url
  "https://music.163.com/api/toplist/detail"
  "NetEase Cloud Music toplist endpoint."
  :type 'string
  :group 'netease-radio)

(defcustom netease-radio-discover-recommended-limit 12
  "Maximum number of recommended playlists shown in Discover."
  :type 'natnum
  :group 'netease-radio)

(defcustom netease-radio-display-style 'child-frame
  "Preferred display style for the now-playing view."
  :type '(choice (const :tag "Child frame" child-frame)
                 (const :tag "Regular buffer" buffer))
  :group 'netease-radio)

(defcustom netease-radio-child-frame-width 24
  "Minimum text width of the now-playing child frame in character columns."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'netease-radio)

(defcustom netease-radio-child-frame-horizontal-padding 2
  "Horizontal padding around the now-playing cover in character columns."
  :type 'natnum
  :group 'netease-radio)

(defcustom netease-radio-cover-cache-directory
  (expand-file-name "covers/" netease-radio-data-directory)
  "Directory used to cache NetEase Cloud Music cover images."
  :type 'directory
  :group 'netease-radio)

(defcustom netease-radio-playlist-max-tracks 50
  "Maximum number of tracks to load from a playlist or album URL."
  :type 'natnum
  :group 'netease-radio)

(defcustom netease-radio-cover-size 160
  "Displayed now-playing cover size in pixels."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'netease-radio)

(defvar netease-radio--state nil
  "Durable state plist for sources and last played track.")

(defvar netease-radio--loaded nil
  "Non-nil once durable state has been loaded.")

(defvar netease-radio--player nil
  "Ephemeral player plist for mpv process and playback state.")

(defvar netease-radio--search-buffer nil
  "Current asynchronous search response buffer.")

(defvar netease-radio--discover-recommended-buffer nil
  "Current asynchronous Discover recommended playlists response buffer.")

(defvar netease-radio--discover-toplist-buffer nil
  "Current asynchronous Discover toplist response buffer.")

(defvar netease-radio--url-import-process nil
  "Current asynchronous yt-dlp import process.")

(defvar netease-radio--loading-message nil
  "Transient loading message shown in the browser header.")

(defvar netease-radio--last-search-query nil
  "Last query passed to `netease-radio-search'.")

(defvar netease-radio--discover-items
  '(:recommended nil :toplists nil :recommended-error nil :toplists-error nil)
  "Cached Discover items and per-section errors.")

(defvar netease-radio--cover-downloads (make-hash-table :test #'equal)
  "Cover image URLs currently being downloaded.")

(defvar netease-radio--cover-failed-urls (make-hash-table :test #'equal)
  "Cover image URLs that failed during this Emacs session.")

(defvar netease-radio--cover-detail-requests (make-hash-table :test #'equal)
  "NetEase song ids currently being queried for cover metadata.")

(defvar netease-radio--cover-detail-failed-ids (make-hash-table :test #'equal)
  "NetEase song ids whose cover metadata lookup failed this session.")

(defvar netease-radio--controls-pixel-width-cache nil
  "Cached pixel width of the now-playing controls row.")

(defvar netease-radio--controls-pixel-width-key nil
  "Cache key for `netease-radio--controls-pixel-width-cache'.")

(defvar netease-radio--browser-view 'home
  "Current browser view: home, discover, search, or now-playing.")

(defconst netease-radio--buffer-name "*netease-radio*"
  "Buffer name for the netease-radio browser.")

(defconst netease-radio--now-playing-buffer-name "*netease-radio-now-playing*"
  "Buffer name for the netease-radio now-playing view.")

(defconst netease-radio--doctor-buffer-name "*netease-radio-doctor*"
  "Buffer name for netease-radio setup diagnostics.")

(defvar netease-radio--frame nil
  "Child frame used to display the now-playing view.")

(defconst netease-radio--browser-heading-padding
  (propertize "\n" 'display '((height 0.25)))
  "Thin vertical padding used below browser headings.")

(defconst netease-radio--now-playing-thin-padding
  (propertize "\n" 'display '((height 0.25)))
  "Thin vertical padding used inside the now-playing view.")

(defconst netease-radio--now-playing-top-padding
  (propertize "\n" 'display '((height 0.5)))
  "Top vertical padding used inside the now-playing view.")

(defconst netease-radio--now-playing-bottom-padding
  ""
  "Bottom vertical padding used inside the now-playing view.")

(defun netease-radio--make-state (&rest plist)
  "Return a durable state plist from PLIST."
  (append plist (list :sources nil :last-track-id nil)))

(defun netease-radio--make-player (&rest plist)
  "Return an ephemeral player plist from PLIST."
  (append plist
          (list :status 'idle
                :current-track nil
                :process nil
                :ipc-process nil
                :socket nil
                :position nil
                :duration nil
                :queue nil
                :queue-index nil
                :repeat 'off
                :shuffle nil
                :stopping nil)))

(setq netease-radio--state (netease-radio--make-state))
(setq netease-radio--player (netease-radio--make-player))

(defun netease-radio--plist-set (symbol property value)
  "Set SYMBOL plist PROPERTY to VALUE."
  (set symbol (plist-put (symbol-value symbol) property value)))

(defun netease-radio--player-set (property value)
  "Set player PROPERTY to VALUE."
  (netease-radio--plist-set 'netease-radio--player property value))

(defun netease-radio--state-set (property value)
  "Set durable state PROPERTY to VALUE."
  (netease-radio--plist-set 'netease-radio--state property value))

(defun netease-radio--sources ()
  "Return known sources in display order."
  (or (plist-get netease-radio--state :sources) nil))

(defun netease-radio--source-id (source)
  "Return SOURCE's identifier."
  (plist-get source :id))

(defun netease-radio--put-source (source)
  "Insert or replace SOURCE in durable state."
  (let* ((id (netease-radio--source-id source))
         (without-source
          (seq-remove (lambda (candidate)
                        (equal (netease-radio--source-id candidate) id))
                      (netease-radio--sources))))
    (netease-radio--state-set :sources (cons source without-source))))

(defun netease-radio--all-tracks ()
  "Return all known tracks in source order."
  (seq-mapcat (lambda (source)
                (copy-sequence (or (plist-get source :tracks) nil)))
              (netease-radio--sources)))

(defun netease-radio--track (id)
  "Return known track with ID, or nil."
  (seq-find (lambda (track)
              (equal (plist-get track :id) id))
            (netease-radio--all-tracks)))

(defun netease-radio--current-track ()
  "Return the current player track, falling back to the last saved track."
  (or (plist-get netease-radio--player :current-track)
      (netease-radio--track (plist-get netease-radio--state :last-track-id))))

(defun netease-radio--ensure-program (program label)
  "Signal a user error unless PROGRAM named LABEL is executable."
  (cond
   ((or (not (stringp program)) (string-empty-p program))
    (user-error "%s program is not configured" label))
   ((file-name-absolute-p program)
    (unless (file-executable-p program)
      (user-error "Cannot execute %s at %s" label program)))
   ((not (executable-find program))
    (user-error "%s program not found: %s" label program))))

(defun netease-radio--song-url (id)
  "Return a playable NetEase Cloud Music song URL for ID."
  (format "https://music.163.com/song?id=%s" (url-hexify-string (format "%s" id))))

(defun netease-radio--track-title (track)
  "Return TRACK's display title."
  (or (plist-get track :title)
      (plist-get track :id)
      "Untitled"))

(defun netease-radio--track-artist (track)
  "Return TRACK's display artist."
  (or (plist-get track :artist) "Unknown artist"))

(defun netease-radio--format-duration (seconds)
  "Return SECONDS formatted as a compact duration."
  (when (numberp seconds)
    (format "%d:%02d" (/ (floor seconds) 60) (% (floor seconds) 60))))

(defun netease-radio--track-label (track)
  "Return TRACK's completion and row label."
  (string-join
   (delq nil
         (list (netease-radio--track-title track)
               (netease-radio--track-artist track)
               (plist-get track :album)))
   " - "))

(defun netease-radio--state-track-p (track)
  "Return non-nil when TRACK has a durable track shape."
  (and (listp track)
       (stringp (plist-get track :id))
       (or (null (plist-get track :title))
           (stringp (plist-get track :title)))
       (or (null (plist-get track :url))
           (stringp (plist-get track :url)))))

(defun netease-radio--state-source-p (source)
  "Return non-nil when SOURCE has a durable source shape."
  (and (listp source)
       (stringp (plist-get source :id))
       (or (null (plist-get source :title))
           (stringp (plist-get source :title)))
       (listp (plist-get source :tracks))
       (seq-every-p #'netease-radio--state-track-p
                    (or (plist-get source :tracks) nil))))

(defun netease-radio--state-data-p (data)
  "Return non-nil when DATA has the supported durable state shape."
  (and (listp data)
       (equal (plist-get data :version) netease-radio--state-version)
       (listp (plist-get data :sources))
       (seq-every-p #'netease-radio--state-source-p
                    (or (plist-get data :sources) nil))
       (or (null (plist-get data :last-track-id))
           (stringp (plist-get data :last-track-id)))))

(defun netease-radio--save ()
  "Persist durable state to `netease-radio-state-file'."
  (make-directory (file-name-directory netease-radio-state-file) t)
  (with-temp-file netease-radio-state-file
    (prin1 (list :version netease-radio--state-version
                 :sources (netease-radio--sources)
                 :last-track-id (plist-get netease-radio--state :last-track-id))
           (current-buffer))))

(defun netease-radio--read-state-file ()
  "Read and validate `netease-radio-state-file'."
  (let* ((read-eval-symbol (intern "read-eval"))
         (read-eval-bound (boundp read-eval-symbol))
         (old-read-eval (and read-eval-bound
                             (symbol-value read-eval-symbol)))
         data)
    (unwind-protect
        (progn
          (set read-eval-symbol nil)
          (setq data
                (with-temp-buffer
                  (insert-file-contents netease-radio-state-file)
                  (read (current-buffer)))))
      (if read-eval-bound
          (set read-eval-symbol old-read-eval)
        (makunbound read-eval-symbol)))
    (unless (netease-radio--state-data-p data)
      (user-error "Invalid netease-radio state file %s" netease-radio-state-file))
    data))

(defun netease-radio--load ()
  "Load durable state from `netease-radio-state-file'."
  (when (file-exists-p netease-radio-state-file)
    (let ((data (netease-radio--read-state-file)))
      (setq netease-radio--state
            (netease-radio--make-state
             :sources (plist-get data :sources)
             :last-track-id (plist-get data :last-track-id))))))

(defun netease-radio--ensure-loaded ()
  "Load durable state once for the current Emacs session."
  (unless netease-radio--loaded
    (netease-radio--load)
    (setq netease-radio--loaded t)))

(defun netease-radio--json-get (object key)
  "Return KEY from JSON alist OBJECT.
KEY may be a symbol; string keys are also checked for `json-parse-*' output."
  (or (alist-get key object)
      (alist-get (symbol-name key) object nil nil #'string=)))

(defun netease-radio--json-number (value &optional divisor)
  "Return VALUE as a number, dividing by DIVISOR when non-nil."
  (when (numberp value)
    (if divisor
        (/ value (float divisor))
      value)))

(defun netease-radio--first-present (&rest values)
  "Return the first non-nil value from VALUES."
  (seq-find #'identity values))

(defun netease-radio--json-first (object &rest keys)
  "Return the first present value for KEYS from JSON alist OBJECT."
  (seq-some (lambda (key)
              (netease-radio--json-get object key))
            keys))

(defun netease-radio--artists-label (artists)
  "Return a display label for NetEase ARTISTS."
  (if (listp artists)
      (string-join
       (delq nil
             (mapcar (lambda (artist)
                       (netease-radio--json-get artist 'name))
                     artists))
       " / ")
    ""))

(defun netease-radio--track-from-search-song (song)
  "Return a track plist from NetEase search SONG."
  (let* ((id (netease-radio--json-get song 'id))
         (album (netease-radio--json-first song 'album 'al))
         (netease-id (format "%s" id)))
    (list :id (concat "netease:" netease-id)
          :netease-id netease-id
          :title (netease-radio--json-first song 'name 'title)
          :artist (netease-radio--artists-label
                   (netease-radio--json-first song 'artists 'ar))
          :album (netease-radio--json-get album 'name)
          :duration (netease-radio--json-number
                     (netease-radio--json-first song 'duration 'dt)
                     1000)
          :url (netease-radio--song-url netease-id)
          :thumbnail-url (netease-radio--json-first album 'picUrl 'pic_url))))

(defun netease-radio--search-source-from-json (query json)
  "Return a source for QUERY from NetEase search JSON."
  (let* ((result (netease-radio--json-get json 'result))
         (songs (netease-radio--json-get result 'songs)))
    (list :id (concat "search:" query)
          :kind 'search
          :title (format "Search: %s" query)
          :tracks (mapcar #'netease-radio--track-from-search-song
                          (or songs nil)))))

(defun netease-radio--search-url (query)
  "Return NetEase search URL for QUERY."
  (concat netease-radio-api-search-url
          "?"
          (url-build-query-string
           `(("csrf_token" "")
             ("type" "1")
             ("offset" "0")
             ("limit" ,(number-to-string netease-radio-search-limit))
             ("s" ,query)))))

(defun netease-radio--discover-playlist-url (id)
  "Return NetEase playlist URL for playlist ID."
  (format "https://music.163.com/#/playlist?id=%s"
          (url-hexify-string (format "%s" id))))

(defun netease-radio--discover-recommended-url ()
  "Return NetEase Discover recommended playlists URL."
  (concat netease-radio-api-discover-playlists-url
          (if (string-match-p "\\?" netease-radio-api-discover-playlists-url)
              "&"
            "?")
          (url-build-query-string
           `(("limit" ,(number-to-string netease-radio-discover-recommended-limit))))))

(defun netease-radio--discover-track-count-subtitle (count)
  "Return a subtitle for track COUNT."
  (when (numberp count)
    (format "%d tracks" count)))

(defun netease-radio--discover-item-from-json (item section)
  "Return a Discover item plist from JSON ITEM in SECTION."
  (let* ((raw-id (netease-radio--json-get item 'id))
         (name (netease-radio--json-get item 'name))
         (id (and raw-id (format "%s" raw-id)))
         (subtitle
          (pcase section
            ('toplist
             (or (netease-radio--json-get item 'updateFrequency)
                 (netease-radio--discover-track-count-subtitle
                  (netease-radio--json-get item 'trackCount))))
            (_
             (netease-radio--discover-track-count-subtitle
              (netease-radio--json-get item 'trackCount))))))
    (when (and id
               (not (string-empty-p id))
               (stringp name)
               (not (string-empty-p name)))
      (list :id id
            :kind 'playlist
            :name name
            :url (netease-radio--discover-playlist-url id)
            :subtitle subtitle
            :section section))))

(defun netease-radio--discover-recommended-items-from-json (json)
  "Return recommended Discover items from JSON."
  (delq nil
        (mapcar (lambda (item)
                  (netease-radio--discover-item-from-json item 'recommended))
                (or (netease-radio--json-get json 'result) nil))))

(defun netease-radio--discover-toplist-items-from-json (json)
  "Return toplist Discover items from JSON."
  (delq nil
        (mapcar (lambda (item)
                  (netease-radio--discover-item-from-json item 'toplist))
                (or (netease-radio--json-get json 'list) nil))))

(defun netease-radio--set-loading (message)
  "Set browser loading MESSAGE and refresh the header."
  (setq netease-radio--loading-message message)
  (when-let* ((buffer (get-buffer netease-radio--buffer-name)))
    (with-current-buffer buffer
      (force-mode-line-update))))

(defun netease-radio--clear-loading ()
  "Clear the browser loading message."
  (netease-radio--set-loading nil))

(defun netease-radio--parse-url-json-buffer ()
  "Parse the current `url-retrieve' buffer as JSON."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "Missing HTTP response body"))
  (json-parse-buffer :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun netease-radio--search-finish (status query)
  "Finish asynchronous search with url-retrieve STATUS for QUERY."
  (unwind-protect
      (if-let* ((error-data (plist-get status :error)))
          (message "NetEase search failed: %s" error-data)
        (let* ((json (netease-radio--parse-url-json-buffer))
               (source (netease-radio--search-source-from-json query json)))
          (netease-radio--put-source source)
          (netease-radio--save)
          (netease-radio--render)
          (message "NetEase search loaded %d tracks"
                   (length (plist-get source :tracks)))))
    (setq netease-radio--search-buffer nil)
    (netease-radio--clear-loading)
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

;;;###autoload
(defun netease-radio-search (query)
  "Search NetEase Cloud Music for QUERY and switch to Search view."
  (interactive "sSearch NetEase: ")
  (netease-radio--ensure-loaded)
  (when (string-empty-p (string-trim query))
    (user-error "Search query is empty"))
  (when (buffer-live-p netease-radio--search-buffer)
    (kill-buffer netease-radio--search-buffer))
  (setq netease-radio--last-search-query query
        netease-radio--browser-view 'search)
  (netease-radio--set-loading (format "Searching %s..." query))
  (let ((url-request-extra-headers
         '(("User-Agent" . "Mozilla/5.0 netease-radio")
           ("Referer" . "https://music.163.com/"))))
    (setq netease-radio--search-buffer
          (url-retrieve (netease-radio--search-url query)
                        #'netease-radio--search-finish
                        (list query)
                        t
                        t))))

(defun netease-radio--discover-section-keys (section)
  "Return item and error plist keys for Discover SECTION."
  (pcase section
    ('recommended (cons :recommended :recommended-error))
    ('toplist (cons :toplists :toplists-error))
    (_ (error "Unknown Discover section %s" section))))

(defun netease-radio--discover-section-title (section)
  "Return display title for Discover SECTION."
  (pcase section
    ('recommended "recommended playlists")
    ('toplist "toplists")
    (_ "Discover")))

(defun netease-radio--discover-set-section (section items error-message)
  "Set Discover SECTION to ITEMS and ERROR-MESSAGE."
  (let* ((keys (netease-radio--discover-section-keys section))
         (items-key (car keys))
         (error-key (cdr keys)))
    (setq netease-radio--discover-items
          (plist-put netease-radio--discover-items items-key items))
    (setq netease-radio--discover-items
          (plist-put netease-radio--discover-items error-key error-message))))

(defun netease-radio--discover-fetching-p ()
  "Return non-nil when any Discover request is running."
  (or (buffer-live-p netease-radio--discover-recommended-buffer)
      (buffer-live-p netease-radio--discover-toplist-buffer)))

(defun netease-radio--discover-clear-loading-maybe ()
  "Clear Discover loading message when no Discover request is running."
  (unless (netease-radio--discover-fetching-p)
    (netease-radio--clear-loading)))

(defun netease-radio--discover-finish (status section)
  "Finish asynchronous Discover request with STATUS for SECTION."
  (unwind-protect
      (condition-case err
          (if-let* ((error-data (plist-get status :error)))
              (progn
                (netease-radio--discover-set-section
                 section nil (format "%s" error-data))
                (message "NetEase Discover %s failed: %s"
                         (netease-radio--discover-section-title section)
                         error-data))
            (let* ((json (netease-radio--parse-url-json-buffer))
                   (items (pcase section
                            ('recommended
                             (netease-radio--discover-recommended-items-from-json json))
                            ('toplist
                             (netease-radio--discover-toplist-items-from-json json)))))
              (netease-radio--discover-set-section section items nil)
              (message "NetEase Discover loaded %d %s"
                       (length items)
                       (netease-radio--discover-section-title section))))
        (error
         (netease-radio--discover-set-section
          section nil (error-message-string err))
         (message "NetEase Discover %s failed: %s"
                  (netease-radio--discover-section-title section)
                  (error-message-string err))))
    (pcase section
      ('recommended (setq netease-radio--discover-recommended-buffer nil))
      ('toplist (setq netease-radio--discover-toplist-buffer nil)))
    (netease-radio--discover-clear-loading-maybe)
    (when (eq netease-radio--browser-view 'discover)
      (netease-radio--render))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun netease-radio--discover-fetch ()
  "Fetch Discover recommended playlists and toplists asynchronously."
  (when (buffer-live-p netease-radio--discover-recommended-buffer)
    (kill-buffer netease-radio--discover-recommended-buffer))
  (when (buffer-live-p netease-radio--discover-toplist-buffer)
    (kill-buffer netease-radio--discover-toplist-buffer))
  (setq netease-radio--discover-items
        (plist-put netease-radio--discover-items :recommended-error nil))
  (setq netease-radio--discover-items
        (plist-put netease-radio--discover-items :toplists-error nil))
  (netease-radio--set-loading "Loading Discover...")
  (let ((url-request-extra-headers
         '(("User-Agent" . "Mozilla/5.0 netease-radio")
           ("Referer" . "https://music.163.com/"))))
    (setq netease-radio--discover-recommended-buffer
          (url-retrieve (netease-radio--discover-recommended-url)
                        #'netease-radio--discover-finish
                        (list 'recommended)
                        t
                        t))
    (setq netease-radio--discover-toplist-buffer
          (url-retrieve netease-radio-api-toplist-url
                        #'netease-radio--discover-finish
                        (list 'toplist)
                        t
                        t))))

(defun netease-radio--refresh-discover ()
  "Refresh the Discover view."
  (setq netease-radio--browser-view 'discover)
  (netease-radio--render)
  (netease-radio--discover-fetch))

;;;###autoload
(defun netease-radio-discover ()
  "Switch to the Discover view and load recommended playlists and toplists."
  (interactive)
  (netease-radio--ensure-loaded)
  (setq netease-radio--browser-view 'discover)
  (pop-to-buffer (netease-radio--buffer))
  (netease-radio--render)
  (netease-radio--discover-fetch))

(defun netease-radio--normalize-url (url)
  "Return URL with NetEase hash-routing stripped for yt-dlp."
  (if (string-match "\\(https?://music\\.163\\.com\\)/#/\\(.*\\)" url)
      (concat (match-string 1 url) "/" (match-string 2 url))
    url))

(defun netease-radio--url-playlist-p (url)
  "Return non-nil when URL looks like a playlist or album."
  (string-match-p "\\(/playlist\\|/album\\|/artist\\)" url))

(defun netease-radio--yt-dlp-cookies-arguments ()
  "Return yt-dlp cookie arguments when `netease-radio-yt-dlp-cookies' is set."
  (when (and (stringp netease-radio-yt-dlp-cookies)
             (not (string-empty-p netease-radio-yt-dlp-cookies))
             (file-readable-p netease-radio-yt-dlp-cookies))
    (list "--cookies" (expand-file-name netease-radio-yt-dlp-cookies))))

(defun netease-radio--yt-dlp-arguments (url)
  "Return yt-dlp metadata arguments for URL."
  (let ((normalized (netease-radio--normalize-url url))
        (common (list "--dump-single-json" "--skip-download")))
    (append common
            (netease-radio--yt-dlp-cookies-arguments)
            (unless (netease-radio--url-playlist-p normalized)
              (list "--no-playlist"))
            (when (netease-radio--url-playlist-p normalized)
              (list "--flat-playlist"
                    "--playlist-end"
                    (number-to-string netease-radio-playlist-max-tracks)))
            (list normalized))))

(defun netease-radio--track-from-ytdlp-json (json fallback-url)
  "Return a track plist from yt-dlp JSON and FALLBACK-URL."
  (let* ((raw-id (or (netease-radio--json-get json 'id) fallback-url))
         (id (format "%s" raw-id))
         (webpage-url (or (netease-radio--json-get json 'webpage_url)
                          (netease-radio--json-get json 'url)
                          (netease-radio--json-get json 'original_url)
                          fallback-url))
         (artist (or (netease-radio--json-get json 'artist)
                     (netease-radio--json-get json 'creator)
                     (netease-radio--json-get json 'uploader)
                     (netease-radio--json-get json 'channel))))
    (list :id (if (string-match-p "\\`[0-9]+\\'" id)
                  (concat "netease:" id)
                (concat "url:" webpage-url))
          :netease-id (and (string-match-p "\\`[0-9]+\\'" id) id)
          :title (netease-radio--json-get json 'title)
          :artist artist
          :album (netease-radio--json-get json 'album)
          :duration (netease-radio--json-number
                     (netease-radio--json-get json 'duration))
          :url webpage-url
          :thumbnail-url (netease-radio--json-get json 'thumbnail))))

(defun netease-radio--track-from-ytdlp-entry (entry fallback-url)
  "Return a track plist from a yt-dlp playlist ENTRY and FALLBACK-URL."
  (netease-radio--track-from-ytdlp-json entry fallback-url))

(defun netease-radio--url-source-from-json (url json)
  "Return a source for URL from yt-dlp JSON.
When JSON contains playlist entries, all entries become tracks."
  (let* ((normalized (netease-radio--normalize-url url))
         (entries (netease-radio--json-get json 'entries)))
    (if (listp entries)
        (list :id (concat "url:" normalized)
              :kind 'playlist
              :title (or (netease-radio--json-get json 'title) normalized)
              :url normalized
              :subtitle (and (numberp (netease-radio--json-get json 'track_count))
                             (format "%s tracks"
                                     (netease-radio--json-get json 'track_count)))
              :tracks (mapcar (lambda (entry)
                                (netease-radio--track-from-ytdlp-entry
                                 entry url))
                              entries))
      (let ((track (netease-radio--track-from-ytdlp-json json url)))
        (list :id (concat "url:" normalized)
              :kind 'url
              :title (or (plist-get track :title) normalized)
              :url normalized
              :tracks (list track))))))

(defun netease-radio--finish-url-import (url stdout-buffer stderr-buffer after-success)
  "Finish importing URL from STDOUT-BUFFER and STDERR-BUFFER.
Run AFTER-SUCCESS with the imported source when non-nil."
  (unwind-protect
      (let ((exit-code (process-exit-status netease-radio--url-import-process)))
        (if (zerop exit-code)
            (let* ((json (with-current-buffer stdout-buffer
                           (goto-char (point-min))
                           (json-parse-buffer :object-type 'alist
                                              :array-type 'list
                                              :null-object nil
                                              :false-object nil)))
                   (source (netease-radio--url-source-from-json url json))
                   (track-count (length (or (plist-get source :tracks) nil))))
              (netease-radio--put-source source)
              (netease-radio--save)
              (netease-radio--render)
              (when (and (> track-count 1)
                         (plist-get source :tracks))
                (netease-radio--batch-fill-metadata
                 (plist-get source :tracks)))
              (when after-success
                (funcall after-success source))
              (message "Imported %s (%d track%s)"
                       (plist-get source :title)
                       track-count
                       (if (= track-count 1) "" "s")))
          (message "yt-dlp failed: %s"
                   (with-current-buffer stderr-buffer
                     (string-trim (buffer-string))))))
    (setq netease-radio--url-import-process nil)
    (netease-radio--clear-loading)
    (when (buffer-live-p stdout-buffer)
      (kill-buffer stdout-buffer))
    (when (buffer-live-p stderr-buffer)
      (kill-buffer stderr-buffer))))

(defun netease-radio--start-url-import (url &optional after-success)
  "Import URL asynchronously and call AFTER-SUCCESS with the source."
  (netease-radio--ensure-program netease-radio-yt-dlp-program "yt-dlp")
  (when (process-live-p netease-radio--url-import-process)
    (user-error "A URL import is already running"))
  (netease-radio--set-loading "Importing URL...")
  (let* ((stdout-buffer (generate-new-buffer " *netease-radio-yt-dlp*"))
         (stderr-buffer (generate-new-buffer " *netease-radio-yt-dlp-stderr*"))
         (process
          (make-process
           :name "netease-radio-yt-dlp"
           :buffer stdout-buffer
           :stderr stderr-buffer
           :noquery t
           :command (cons netease-radio-yt-dlp-program
                          (netease-radio--yt-dlp-arguments url)))))
    (setq netease-radio--url-import-process process)
    (set-process-sentinel
     process
     (lambda (proc _event)
       (when (and (not (process-live-p proc))
                  (eq proc netease-radio--url-import-process))
         (netease-radio--finish-url-import
          url stdout-buffer stderr-buffer after-success))))))

;;;###autoload
(defun netease-radio-add-or-add-url ()
  "Add a playlist, save Discover item, or import a URL."
  (interactive)
  (netease-radio--ensure-loaded)
  (pcase netease-radio--browser-view
    ('home
     (let* ((url (read-string "Playlist URL: "))
            (fetched-name (netease-radio--fetch-playlist-title url))
            (default-name (or fetched-name url))
            (name (read-string (format "Playlist name (%s): " default-name)
                               nil nil default-name)))
       (netease-radio-add-playlist url name)))
    ('discover
     (if-let* ((item (netease-radio--discover-item-at-point)))
         (netease-radio--save-discover-item item)
       (user-error "No Discover item at point")))
    (_
     (call-interactively #'netease-radio-add-url))))

;;;###autoload
(defun netease-radio-add-url (url)
  "Import and play a NetEase Cloud Music URL.
For playlist or album URLs, imports the track list without
starting playback."
  (interactive "sNetEase URL: ")
  (netease-radio--ensure-loaded)
  (netease-radio--start-url-import
   url
   (lambda (source)
     (when-let* ((tracks (plist-get source :tracks)))
       (setq netease-radio--browser-view 'search)
       (netease-radio--set-playback-queue tracks (car tracks))
       (unless (> (length tracks) 1)
         (netease-radio--play-track (car tracks)))))))

(defun netease-radio--mpv-ytdl-format-argument ()
  "Return the mpv ytdl format argument, or nil."
  (when (and (stringp netease-radio-mpv-ytdl-format)
             (not (string-empty-p netease-radio-mpv-ytdl-format)))
    (concat "--ytdl-format=" netease-radio-mpv-ytdl-format)))

(defun netease-radio--mpv-ytdl-cookies-argument ()
  "Return mpv ytdl-raw-options cookies when `netease-radio-yt-dlp-cookies' is set."
  (when (and (stringp netease-radio-yt-dlp-cookies)
             (not (string-empty-p netease-radio-yt-dlp-cookies))
             (file-readable-p netease-radio-yt-dlp-cookies))
    (concat "--ytdl-raw-options=cookies="
            (expand-file-name netease-radio-yt-dlp-cookies))))

(defun netease-radio--mpv-arguments (socket url)
  "Return mpv arguments for SOCKET and media URL."
  (append (delq nil
                (list "--no-video"
                      "--force-window=no"
                      (netease-radio--mpv-ytdl-format-argument)
                      (netease-radio--mpv-ytdl-cookies-argument)
                      (concat "--input-ipc-server=" socket)))
          netease-radio-mpv-extra-args
          (list url)))

(defun netease-radio--mpv-ipc-writable-p (ipc)
  "Return non-nil when IPC process can probably accept writes."
  (and (process-live-p ipc)
       (memq (process-status ipc) '(open run))))

(defun netease-radio--mpv-ready-p ()
  "Return non-nil when the current mpv process can accept IPC commands."
  (let ((process (plist-get netease-radio--player :process))
        (ipc-process (plist-get netease-radio--player :ipc-process)))
    (and process
         ipc-process
         (process-live-p process)
         (netease-radio--mpv-ipc-writable-p ipc-process))))

(defun netease-radio--current-mpv-ipc-p (process)
  "Return non-nil when PROCESS is the active mpv IPC connection."
  (eq process (plist-get netease-radio--player :ipc-process)))

(defun netease-radio--mpv-send (&rest command)
  "Send COMMAND to the current mpv IPC process."
  (when-let* ((ipc (plist-get netease-radio--player :ipc-process))
              ((netease-radio--mpv-ipc-writable-p ipc)))
    (condition-case nil
        (progn
          (process-send-string
           ipc
           (concat (json-encode `((command . ,(vconcat command)))) "\n"))
          t)
      (error
       (when (eq ipc (plist-get netease-radio--player :ipc-process))
         (netease-radio--player-set :ipc-process nil))
       nil))))

(defun netease-radio--set-status (status)
  "Set player STATUS and refresh UI."
  (netease-radio--player-set :status status)
  (netease-radio--render))

(defun netease-radio--set-playback-property (property value)
  "Set playback PROPERTY to VALUE and refresh now-playing UI."
  (netease-radio--player-set property value)
  (netease-radio--render-now-playing))

(defun netease-radio--set-current-track-state (track status position)
  "Set current TRACK, STATUS, and POSITION in player state."
  (netease-radio--player-set :current-track track)
  (netease-radio--player-set :status status)
  (netease-radio--player-set :position position)
  (netease-radio--player-set :duration (plist-get track :duration))
  (netease-radio--state-set :last-track-id (plist-get track :id)))

(defun netease-radio--mpv-event (event msg)
  "Mirror mpv EVENT and MSG into player state."
  (pcase event
    ("property-change"
     (pcase (netease-radio--json-get msg 'name)
       ("pause"
        (netease-radio--set-status
         (if (netease-radio--json-get msg 'data) 'paused 'playing)))
       ("core-idle"
        (unless (netease-radio--json-get msg 'data)
          (netease-radio--set-status 'playing)))
       ("time-pos"
        (netease-radio--set-playback-property
         :position (netease-radio--json-get msg 'data)))
       ("duration"
        (netease-radio--set-playback-property
         :duration (netease-radio--json-get msg 'data)))))
    ("end-file"
     (when (equal (netease-radio--json-get msg 'reason) "error")
       (netease-radio--set-status 'stopped)
       (message "Playback error: %s"
                (or (netease-radio--json-get msg 'file_error)
                    "unknown error"))))))

(defun netease-radio--mpv-dispatch (process line)
  "Dispatch one mpv JSON message LINE from PROCESS."
  (when-let* (((netease-radio--current-mpv-ipc-p process))
              (msg (ignore-errors
                     (json-parse-string line
                                        :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil)))
              (event (netease-radio--json-get msg 'event)))
    (netease-radio--mpv-event event msg)))

(defun netease-radio--mpv-filter (process output)
  "Parse newline-delimited JSON OUTPUT from mpv PROCESS."
  (condition-case nil
      (when (netease-radio--current-mpv-ipc-p process)
        (let ((pending (concat (or (process-get process 'pending) "") output)))
          (while (string-match "\n" pending)
            (let ((line (substring pending 0 (match-beginning 0))))
              (setq pending (substring pending (match-end 0)))
              (netease-radio--mpv-dispatch process line)))
          (process-put process 'pending pending)))
    (error
     (process-put process 'pending ""))))

(defun netease-radio--mpv-connect (socket process attempt)
  "Connect to mpv SOCKET for PROCESS, retrying from ATTEMPT."
  (when (and (< attempt 40)
             (process-live-p process)
             (eq process (plist-get netease-radio--player :process)))
    (condition-case nil
        (let ((ipc (make-network-process
                    :name "netease-radio-mpv-ipc"
                    :family 'local
                    :service socket
                    :coding 'utf-8
                    :noquery t
                    :filter #'netease-radio--mpv-filter)))
          (process-put ipc 'pending "")
          (netease-radio--player-set :ipc-process ipc)
          (netease-radio--mpv-send "observe_property" 1 "pause")
          (netease-radio--mpv-send "observe_property" 2 "core-idle")
          (netease-radio--mpv-send "observe_property" 3 "time-pos")
          (netease-radio--mpv-send "observe_property" 4 "duration"))
      (error
       (run-at-time 0.05 nil
                    #'netease-radio--mpv-connect socket process (1+ attempt))))))

(defun netease-radio--stop-process ()
  "Stop the current mpv process and IPC connection."
  (let ((process (plist-get netease-radio--player :process))
        (ipc-process (plist-get netease-radio--player :ipc-process)))
    (netease-radio--player-set :stopping t)
    (netease-radio--player-set :process nil)
    (netease-radio--player-set :ipc-process nil)
    (netease-radio--player-set :socket nil)
    (netease-radio--player-set :position nil)
    (netease-radio--player-set :duration nil)
    (netease-radio--player-set :status 'stopped)
    (when (process-live-p ipc-process)
      (delete-process ipc-process))
    (when (process-live-p process)
      (delete-process process))
    (netease-radio--player-set :stopping nil)))

(defun netease-radio--queued-neighbor-track (direction)
  "Return neighbor track in DIRECTION from the runtime queue."
  (let ((queue (plist-get netease-radio--player :queue))
        (index (plist-get netease-radio--player :queue-index)))
    (when (and (listp queue) (integerp index))
      (or (and (plist-get netease-radio--player :shuffle)
               (eq direction 'next)
               (> (length queue) 1)
               (seq-random-elt
                (seq-remove (lambda (track)
                              (equal (plist-get track :id)
                                     (plist-get (nth index queue) :id)))
                            queue)))
          (nth (pcase direction
                 ('next (1+ index))
                 ('previous (1- index)))
               queue)
          (when (eq (plist-get netease-radio--player :repeat) 'all)
            (pcase direction
              ('next (car queue))
              ('previous (car (last queue)))))))))

(defun netease-radio--sync-queue-index (track)
  "Set runtime queue index to TRACK's position when present."
  (let ((queue (plist-get netease-radio--player :queue)))
    (when-let* ((index (cl-position (plist-get track :id)
                                    queue
                                    :key (lambda (candidate)
                                           (plist-get candidate :id))
                                    :test #'equal)))
      (netease-radio--player-set :queue-index index))))

(defun netease-radio--set-playback-queue (tracks current-track)
  "Set runtime playback queue to TRACKS around CURRENT-TRACK."
  (netease-radio--player-set :queue tracks)
  (netease-radio--player-set
   :queue-index
   (or (cl-position (plist-get current-track :id)
                    tracks
                    :key (lambda (track) (plist-get track :id))
                    :test #'equal)
       0)))

(defun netease-radio--playback-url (track)
  "Return TRACK's playback URL."
  (or (plist-get track :url)
      (when-let* ((id (plist-get track :netease-id)))
        (netease-radio--song-url id))))

(defun netease-radio--play-track (track)
  "Play TRACK with mpv."
  (netease-radio--ensure-program netease-radio-mpv-program "mpv")
  (let ((url (netease-radio--playback-url track)))
    (unless url
      (user-error "Track has no playable URL"))
    (netease-radio--sync-queue-index track)
    (if (and (netease-radio--mpv-ready-p)
             (netease-radio--mpv-send "loadfile" url "replace"))
        (progn
          (netease-radio--set-current-track-state track 'loading nil)
          (netease-radio--mpv-send "set_property" "pause" :json-false)
          (netease-radio--save)
          (netease-radio--render)
          (netease-radio--show-now-playing nil)
          (message "Playing %s" (netease-radio--track-label track)))
      (netease-radio--stop-process)
      (let* ((socket (make-temp-name
                      (expand-file-name "netease-radio-mpv-" temporary-file-directory)))
             (args (netease-radio--mpv-arguments socket url))
             (process (apply #'start-process
                             "netease-radio-mpv" nil netease-radio-mpv-program args)))
        (set-process-sentinel process #'netease-radio--mpv-sentinel)
        (netease-radio--player-set :process process)
        (netease-radio--player-set :socket socket)
        (netease-radio--set-current-track-state track 'loading nil)
        (netease-radio--save)
        (netease-radio--mpv-connect socket process 0)
        (netease-radio--render)
        (netease-radio--show-now-playing nil)
        (message "Playing %s" (netease-radio--track-label track))))))

(defun netease-radio--mpv-sentinel (process _event)
  "Advance when mpv PROCESS exits cleanly."
  (when (and (not (process-live-p process))
             (eq process (plist-get netease-radio--player :process)))
    (if-let* (((not (plist-get netease-radio--player :stopping)))
              (next (and (or (zerop (process-exit-status process))
                             (eq (plist-get netease-radio--player :repeat) 'one))
                         (or (and (eq (plist-get netease-radio--player :repeat) 'one)
                                  (netease-radio--current-track))
                             (netease-radio--queued-neighbor-track 'next)))))
        (netease-radio--play-track next)
      (netease-radio--stop-process)
      (netease-radio--render))))

;;;###autoload
(defun netease-radio-toggle-pause ()
  "Toggle mpv pause state."
  (interactive)
  (unless (netease-radio--mpv-send "cycle" "pause")
    (user-error "mpv is not ready")))

;;;###autoload
(defun netease-radio-stop ()
  "Stop playback."
  (interactive)
  (netease-radio--stop-process)
  (netease-radio--render))

;;;###autoload
(defun netease-radio-next ()
  "Play the next track in the runtime queue."
  (interactive)
  (if-let* ((track (netease-radio--queued-neighbor-track 'next)))
      (netease-radio--play-track track)
    (user-error "No next track")))

;;;###autoload
(defun netease-radio-previous ()
  "Play the previous track in the runtime queue."
  (interactive)
  (if-let* ((track (netease-radio--queued-neighbor-track 'previous)))
      (netease-radio--play-track track)
    (user-error "No previous track")))

;;;###autoload
(defun netease-radio-cycle-repeat ()
  "Cycle repeat mode between off, all, and one."
  (interactive)
  (let ((repeat (pcase (plist-get netease-radio--player :repeat)
                  ('off 'all)
                  ('all 'one)
                  (_ 'off))))
    (netease-radio--player-set :repeat repeat)
    (netease-radio--render)
    (message "Repeat: %s" repeat)))

;;;###autoload
(defun netease-radio-toggle-shuffle ()
  "Toggle shuffle mode."
  (interactive)
  (let ((shuffle (not (plist-get netease-radio--player :shuffle))))
    (netease-radio--player-set :shuffle shuffle)
    (netease-radio--render)
    (message "Shuffle: %s" (if shuffle "on" "off"))))

(defun netease-radio--seek (seconds)
  "Seek mpv by SECONDS."
  (unless (netease-radio--mpv-send "seek" seconds "relative")
    (user-error "mpv is not ready")))

;;;###autoload
(defun netease-radio-seek-forward ()
  "Seek forward ten seconds."
  (interactive)
  (netease-radio--seek 10))

;;;###autoload
(defun netease-radio-seek-backward ()
  "Seek backward ten seconds."
  (interactive)
  (netease-radio--seek -10))

;;;###autoload
(defun netease-radio-share ()
  "Copy the current track URL."
  (interactive)
  (if-let* ((track (netease-radio--current-track))
            (url (netease-radio--playback-url track)))
      (progn
        (kill-new url)
        (message "Copied %s" url))
    (user-error "No current track")))

;;;###autoload
(defun netease-radio-play-track (track-id)
  "Select and play a known track by TRACK-ID."
  (interactive
   (let* ((tracks (progn
                    (netease-radio--ensure-loaded)
                    (netease-radio--all-tracks)))
          (candidates
           (mapcar (lambda (track)
                     (cons (netease-radio--track-label track)
                           (plist-get track :id)))
                   tracks)))
     (unless candidates
       (user-error "No known tracks; run `netease-radio-search' first"))
     (list (cdr (assoc (completing-read "Track: " candidates nil t)
                       candidates)))))
  (if-let* ((track (netease-radio--track track-id)))
      (progn
        (netease-radio--set-playback-queue (netease-radio--all-tracks) track)
        (netease-radio--play-track track))
    (user-error "Unknown track %s" track-id)))

;;; UI

(define-button-type 'netease-radio-browser-button
  'follow-link t
  'mouse-face 'highlight)

(define-button-type 'netease-radio-now-playing-button
  'follow-link t
  'face 'default
  'mouse-face 'highlight)

(defvar netease-radio-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'netease-radio-add-or-add-url)
    (define-key map (kbd "c") #'netease-radio-now-playing)
    (define-key map (kbd "RET") #'netease-radio-open-at-point)
    (define-key map (kbd "d") #'netease-radio-remove-playlist-at-point)
    (define-key map (kbd "j") #'netease-radio-next-item)
    (define-key map (kbd "k") #'netease-radio-previous-item)
    (define-key map (kbd "<down>") #'netease-radio-next-item)
    (define-key map (kbd "<up>") #'netease-radio-previous-item)
    (define-key map (kbd "g") #'netease-radio-refresh)
    (define-key map (kbd "/") #'netease-radio-search)
    (define-key map (kbd "TAB") #'netease-radio-next-section)
    (define-key map (kbd "<backtab>") #'netease-radio-previous-section)
    (define-key map (kbd "s") #'netease-radio-play-source)
    (define-key map (kbd "SPC") #'netease-radio-toggle-pause)
    (define-key map (kbd "n") #'netease-radio-next)
    (define-key map (kbd "p") #'netease-radio-previous)
    (define-key map (kbd "r") #'netease-radio-cycle-repeat)
    (define-key map (kbd "x") #'netease-radio-toggle-shuffle)
    (define-key map (kbd "S") #'netease-radio-share)
    (define-key map (kbd "f") #'netease-radio-seek-forward)
    (define-key map (kbd "B") #'netease-radio-seek-backward)
    (define-key map (kbd "q") #'netease-radio-hide-browser)
    (define-key map (kbd "Q") #'netease-radio-stop)
    (define-key map (kbd "H") #'netease-radio-home-view)
    (define-key map (kbd "D") #'netease-radio-discover)
    (define-key map (kbd "N") #'netease-radio-now-playing-browser-view)
    map)
  "Keymap for `netease-radio-mode'.")

(define-derived-mode netease-radio-mode special-mode "netease-radio"
  "Major mode for the netease-radio browser buffer."
  (setq-local mode-line-format nil)
  (setq-local header-line-format '(:eval (netease-radio--browser-header-line))))

(defvar netease-radio--now-playing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'netease-radio-toggle-pause)
    (define-key map (kbd "n") #'netease-radio-next)
    (define-key map (kbd "p") #'netease-radio-previous)
    (define-key map (kbd "r") #'netease-radio-cycle-repeat)
    (define-key map (kbd "x") #'netease-radio-toggle-shuffle)
    (define-key map (kbd "S") #'netease-radio-share)
    (define-key map (kbd "f") #'netease-radio-seek-forward)
    (define-key map (kbd "B") #'netease-radio-seek-backward)
    (define-key map (kbd "q") #'netease-radio-hide-now-playing)
    (dolist (command '(scroll-up-command scroll-down-command
                       scroll-up scroll-down scroll-left scroll-right
                       mwheel-scroll pixel-scroll-precision))
      (define-key map (vector 'remap command) #'ignore))
    map)
  "Keymap for `netease-radio--now-playing-mode'.")

(define-derived-mode netease-radio--now-playing-mode special-mode "netease-radio-now"
  "Major mode for the netease-radio now-playing view."
  (setq-local mode-line-format nil)
  (setq-local cursor-type nil)
  (setq-local truncate-lines nil))

(defun netease-radio--buffer ()
  "Return the netease-radio browser buffer, creating it when needed."
  (let ((buffer (get-buffer-create netease-radio--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'netease-radio-mode)
        (netease-radio-mode)))
    buffer))

(defun netease-radio--now-playing-buffer ()
  "Return the netease-radio now-playing buffer, creating it when needed."
  (let ((buffer (get-buffer-create netease-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'netease-radio--now-playing-mode)
        (netease-radio--now-playing-mode)))
    buffer))

(defun netease-radio--faicon (name fallback)
  "Return nerd-icons Font Awesome NAME, or FALLBACK."
  (if (and (require 'nerd-icons nil t)
           (fboundp 'nerd-icons-faicon))
      (condition-case nil
          (funcall #'nerd-icons-faicon name :height 1.0)
        (error fallback))
    fallback))

(defun netease-radio--mdicon (name fallback)
  "Return nerd-icons Material Design NAME, or FALLBACK."
  (if (and (require 'nerd-icons nil t)
           (fboundp 'nerd-icons-mdicon))
      (condition-case nil
          (funcall #'nerd-icons-mdicon name :height 1.0)
        (error fallback))
    fallback))

(defun netease-radio--browser-header-logo ()
  "Return the NetEase Cloud Music browser header logo."
  (propertize (netease-radio--faicon "nf-fa-music" "NCM")
              'face 'netease-radio-header-logo))

(defun netease-radio--browser-header-item (label active)
  "Return a browser header LABEL with ACTIVE state."
  (propertize label
              'face (if active
                        'netease-radio-header-active
                      'netease-radio-header-inactive)))

(defun netease-radio--browser-header-line ()
  "Return the netease-radio browser header line."
  (let* ((view netease-radio--browser-view)
         (status netease-radio--loading-message)
         (tabs (mapconcat
                #'identity
                (list (netease-radio--browser-header-item
                       "Home" (eq view 'home))
                      (netease-radio--browser-header-item
                       "Discover" (eq view 'discover))
                      (netease-radio--browser-header-item
                       "Search" (eq view 'search))
                      (netease-radio--browser-header-item
                       "Now Playing" (eq view 'now-playing)))
                "   ")))
    (concat
     " "
     (netease-radio--browser-header-logo)
     "    "
     tabs
     (when status
       (concat "    " (propertize status 'face 'shadow))))))

(defun netease-radio--point-property (property)
  "Return PROPERTY at point or the previous character."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) property))))

(defun netease-radio--track-at-point ()
  "Return track stored at point, or nil."
  (netease-radio--point-property 'netease-radio-track))

(defun netease-radio--source-at-point ()
  "Return source stored at point, or nil."
  (netease-radio--point-property 'netease-radio-source))

(defun netease-radio--source-summary (source)
  "Return a compact summary for SOURCE."
  (or (when (stringp (plist-get source :subtitle))
        (plist-get source :subtitle))
      (let ((count (length (or (plist-get source :tracks) nil))))
        (if (= count 1)
            "1 song"
          (format "%d songs" count)))))

(defun netease-radio--insert-browser-heading-padding ()
  "Insert ytm-radio style heading padding."
  (insert netease-radio--browser-heading-padding))

(defun netease-radio--insert-action-button (label action &optional face)
  "Insert a browser action button LABEL running ACTION."
  (insert-text-button label
                      'type 'netease-radio-browser-button
                      'action (lambda (_button) (funcall action))
                      'face (or face 'link)))

(defun netease-radio--track-detail (track)
  "Return metadata detail text for TRACK."
  (string-join
   (delq nil
         (list (netease-radio--track-artist track)
               (plist-get track :album)
               (netease-radio--format-duration (plist-get track :duration))))
   "  -  "))

(defun netease-radio--insert-track-row (source track index)
  "Insert TRACK row belonging to SOURCE at INDEX."
  (let* ((start (point))
         (current (netease-radio--current-track))
         (current-p (and current
                         (equal (plist-get current :id)
                                (plist-get track :id)))))
    (insert (format "%s %2d. "
                    (if current-p ">" " ")
                    index))
    (insert-text-button
     (netease-radio--track-title track)
     'type 'netease-radio-browser-button
     'face (if current-p 'netease-radio-current-track 'netease-radio-track-title)
     'action (lambda (_button)
               (netease-radio--set-playback-queue
                (plist-get source :tracks)
                track)
               (netease-radio--play-track track)))
    (insert "\n     "
            (propertize (netease-radio--track-detail track) 'face 'shadow)
            "\n")
    (add-text-properties start (point)
                         (list 'netease-radio-track track
                               'netease-radio-source source))
    (add-text-properties start (min (point) (1+ start))
                         (list 'netease-radio-track-start t))))

(defun netease-radio--insert-source-section (source &optional omit-leading-space)
  "Insert SOURCE as a browser section.
When OMIT-LEADING-SPACE is non-nil, do not insert the leading blank line."
  (let ((tracks (or (plist-get source :tracks) nil))
        (start (point)))
    (unless omit-leading-space
      (insert "\n"))
    (insert-text-button (or (plist-get source :title) "Untitled source")
                        'type 'netease-radio-browser-button
                        'action (lambda (_button)
                                  (netease-radio-play-source source))
                        'face 'netease-radio-section-title)
    (add-text-properties start (point)
                         (list 'netease-radio-section t
                               'netease-radio-source source))
    (add-text-properties start (min (point) (1+ start))
                         (list 'netease-radio-section-start t))
    (insert "  "
            (propertize (netease-radio--source-summary source) 'face 'shadow)
            "\n")
    (netease-radio--insert-browser-heading-padding)
    (if tracks
        (cl-loop for track in tracks
                 for index from 1
                 do (netease-radio--insert-track-row source track index))
      (insert (propertize "  No tracks\n" 'face 'shadow)))
    (insert "\n")))

(defun netease-radio--render ()
  "Render all visible netease-radio buffers."
  (netease-radio--render-browser)
  (netease-radio--render-now-playing))

(defun netease-radio--render-browser ()
  "Render the netease-radio browser based on `netease-radio--browser-view'."
  (when-let* ((buffer (get-buffer netease-radio--buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (netease-radio--insert-browser-heading-padding)
        (pcase netease-radio--browser-view
          ('home (netease-radio--render-home))
          ('discover (netease-radio--render-discover))
          ('search (netease-radio--render-search))
          ('now-playing (netease-radio--render-now-playing-browser)))
        (goto-char (point-min))
        (force-mode-line-update)))))

(defun netease-radio--read-dashboard-playlists ()
  "Return saved dashboard playlists as a list of plists."
  (let ((file (expand-file-name "dashboard.eld" netease-radio-data-directory)))
    (when (file-exists-p file)
      (let ((data
             (with-temp-buffer
               (insert-file-contents file)
               (read (current-buffer)))))
        (when (listp data)
          data)))))

(defun netease-radio--save-dashboard-playlists (playlists)
  "Save PLAYLISTS to the dashboard state file."
  (make-directory (file-name-directory
                    (expand-file-name "dashboard.eld" netease-radio-data-directory))
                   t)
  (with-temp-file (expand-file-name "dashboard.eld" netease-radio-data-directory)
    (prin1 playlists (current-buffer))))

(defun netease-radio--save-dashboard-playlist (url name)
  "Save playlist URL and NAME to the dashboard state file.
Return the saved playlist entry."
  (setq name (string-trim (or name "")))
  (when (string-empty-p name)
    (user-error "Playlist name cannot be empty"))
  (when (string-empty-p (string-trim url))
    (user-error "Playlist URL cannot be empty"))
  (let* ((normalized (netease-radio--normalize-url url))
         (id (secure-hash 'sha1 normalized))
         (entry (list :id id :name name :url normalized))
         (playlists (or (netease-radio--read-dashboard-playlists) nil))
         (existing (seq-remove
                    (lambda (p)
                      (equal (plist-get p :id) id))
                    playlists)))
    (netease-radio--save-dashboard-playlists (cons entry existing))
    entry))

(defun netease-radio--fetch-playlist-title (url)
  "Return the playlist title for URL using yt-dlp."
  (let* ((normalized (netease-radio--normalize-url url))
         (default-directory temporary-file-directory)
         (cookies-args (netease-radio--yt-dlp-cookies-arguments)))
    (with-temp-buffer
      (let ((exit-code
             (apply #'call-process netease-radio-yt-dlp-program
                    nil (current-buffer) nil
                    "--dump-single-json"
                    "--flat-playlist"
                    "--playlist-end" "1"
                    "--skip-download"
                    (append cookies-args (list normalized)))))
        (when (zerop exit-code)
          (goto-char (point-min))
          (ignore-errors
            (let* ((json (json-parse-buffer :object-type 'alist
                                           :array-type 'list
                                           :null-object nil
                                           :false-object nil))
                   (title (netease-radio--json-get json 'title))
                   (track-count (netease-radio--json-get json 'track_count)))
              (if (numberp track-count)
                  (format "%s (%d tracks)" (or title url) track-count)
                (or title url)))))))))

;;;###autoload
(defun netease-radio-add-playlist (url &optional name)
  "Add a NetEase Cloud Music playlist to the Home view.
URL is the playlist link.  NAME is fetched from NetEase automatically."
  (interactive
   (let* ((url (read-string "Playlist URL: "))
          (fetched-name (netease-radio--fetch-playlist-title url))
          (default-name (or fetched-name url)))
     (list url
           (read-string (format "Playlist name (%s): " default-name)
                        nil nil default-name))))
  (netease-radio--save-dashboard-playlist url name)
  (netease-radio-home-view)
  (message "Saved playlist %s" name))

(defun netease-radio--home-playlist-at-point ()
  "Return the dashboard playlist at point, or nil."
  (or (get-text-property (point) 'netease-dashboard-playlist)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'netease-dashboard-playlist))))

(defun netease-radio-remove-playlist-at-point ()
  "Remove the playlist at point from the Home view."
  (interactive)
  (if-let* ((playlist (netease-radio--home-playlist-at-point)))
      (let ((id (plist-get playlist :id))
            (name (plist-get playlist :name)))
        (netease-radio--save-dashboard-playlists
         (seq-remove (lambda (p)
                        (equal (plist-get p :id) id))
                      (or (netease-radio--read-dashboard-playlists) nil)))
        (netease-radio-home-view)
        (message "Removed playlist %s" name))
    (user-error "No playlist at point")))

(defun netease-radio--render-home ()
  "Render the Home view (saved playlists)."
  (insert "  "
          (propertize "NetEase Cloud Music"
                      'face 'netease-radio-home-header)
          "\n")
  (insert "  "
          (propertize "Saved Playlists"
                      'face 'shadow)
          "\n\n")
  (let ((playlists (netease-radio--read-dashboard-playlists)))
    (if playlists
        (dolist (playlist playlists)
          (let ((start (point))
                (name (plist-get playlist :name))
                (url (plist-get playlist :url)))
            (insert "  ")
            (insert-text-button
             name
             'type 'netease-radio-browser-button
             'face 'netease-radio-home-playlist-title
             'action (lambda (_button)
                       (setq netease-radio--browser-view 'search)
                       (message "Loading playlist %s..." name)
                       (netease-radio--start-url-import
                        url
                        (lambda (source)
                          (when-let* ((tracks (plist-get source :tracks)))
                            (netease-radio--set-playback-queue
                             tracks (car tracks))
                            (message "Loaded %d tracks"
                                     (length tracks)))))))
            (insert "\n"
                    "    "
                    (propertize url 'face 'shadow)
                    "  "
                    (propertize "[d] remove" 'face 'shadow)
                    "\n\n")
            (add-text-properties start (point)
                                 (list 'netease-dashboard-playlist playlist))))
      (insert "  No playlists saved yet.\n")
      (insert "  Press a to save a playlist URL.\n"))))

(defun netease-radio--discover-item-at-point ()
  "Return the Discover item at point, or nil."
  (or (get-text-property (point) 'netease-discover-item)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'netease-discover-item))))

(defun netease-radio--save-discover-item (item)
  "Save Discover ITEM as a dashboard playlist."
  (netease-radio--save-dashboard-playlist
   (plist-get item :url)
   (plist-get item :name)))

(defun netease-radio--render-discover-section (title items error)
  "Render a Discover section with TITLE, list of ITEMS, and optional ERROR."
  (insert "\n")
  (insert-text-button title
                      'type 'netease-radio-browser-button
                      'face 'netease-radio-section-title
                      'action #'ignore)
  (insert "\n")
  (netease-radio--insert-browser-heading-padding)
  (cond
   (error
    (insert "  " (propertize (format "Error: %s" error) 'face 'shadow) "\n"))
   ((not items)
    (insert "  " (propertize "Loading..." 'face 'shadow) "\n"))
   (t
    (dolist (item items)
      (let ((start (point))
            (name (plist-get item :name))
            (subtitle (plist-get item :subtitle))
            (url (plist-get item :url)))
        (insert "  ")
        (insert-text-button
         name
         'type 'netease-radio-browser-button
         'face 'netease-radio-home-playlist-title
         'action (lambda (_button)
                   (setq netease-radio--browser-view 'search)
                   (message "Loading playlist %s..." name)
                   (netease-radio--start-url-import
                    url
                    (lambda (source)
                      (when-let* ((tracks (plist-get source :tracks)))
                        (netease-radio--set-playback-queue
                         tracks (car tracks))
                        (message "Loaded %d tracks"
                                 (length tracks)))))))
        (when subtitle
          (insert "  " (propertize subtitle 'face 'shadow)))
        (insert "\n")
        (add-text-properties start (point)
                             (list 'netease-discover-item item)))))))

(defun netease-radio--render-discover ()
  "Render the Discover view (recommended playlists and toplists)."
  (insert "  "
          (propertize "Discover"
                      'face 'netease-radio-home-header)
          "\n")
  (insert "  "
          (propertize "Browse recommended playlists and charts from NetEase Cloud Music."
                      'face 'shadow)
          "\n")
  (netease-radio--render-discover-section
   "Recommended Playlists"
   (plist-get netease-radio--discover-items :recommended)
   (plist-get netease-radio--discover-items :recommended-error))
  (netease-radio--render-discover-section
   "Toplists"
   (plist-get netease-radio--discover-items :toplists)
   (plist-get netease-radio--discover-items :toplists-error)))

(defun netease-radio--render-search ()
  "Render the Search view (search results)."
  (if-let* ((sources (netease-radio--sources)))
      (cl-loop for source in sources
               for first = t then nil
               do (netease-radio--insert-source-section source first))
    (insert "Press / to search NetEase Cloud Music.\n")))

(defun netease-radio--render-now-playing-browser ()
  "Render the Now Playing view (current queue)."
  (let ((queue (plist-get netease-radio--player :queue)))
    (if queue
        (let ((source (list :id "queue"
                            :title "Play Queue"
                            :tracks queue)))
          (netease-radio--insert-source-section source t))
      (insert "No tracks in queue.\n")
      (insert "Load a playlist from Home or search for songs.\n")))
  (insert "\n"
          (propertize "Press c to open the mini-player child-frame."
                      'face 'shadow)))

;;;###autoload
(defun netease-radio-home-view ()
  "Switch to the Home view in the netease-radio browser."
  (interactive)
  (setq netease-radio--browser-view 'home)
  (netease-radio--ensure-loaded)
  (pop-to-buffer netease-radio--buffer-name)
  (netease-radio--render))

;;;###autoload
(defun netease-radio-search-view ()
  "Switch to the Search view in the netease-radio browser."
  (interactive)
  (setq netease-radio--browser-view 'search)
  (pop-to-buffer netease-radio--buffer-name)
  (netease-radio--render))

;;;###autoload
(defun netease-radio-now-playing-browser-view ()
  "Switch to the Now Playing view in the netease-radio browser."
  (interactive)
  (setq netease-radio--browser-view 'now-playing)
  (pop-to-buffer netease-radio--buffer-name)
  (netease-radio--render))

(defun netease-radio--goto-track (track-id)
  "Move point to rendered TRACK-ID."
  (goto-char (point-min))
  (let (found)
    (while (and (not found)
                (< (point) (point-max)))
      (let ((track (get-text-property (point) 'netease-radio-track)))
        (if (and track (equal (plist-get track :id) track-id))
            (setq found t)
          (goto-char (or (next-single-property-change
                          (point) 'netease-radio-track nil (point-max))
                         (point-max))))))))

(defun netease-radio--start-property-positions (property)
  "Return buffer positions whose PROPERTY is non-nil."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (get-text-property (point) property)
          (push (point) positions))
        (goto-char (or (next-single-property-change
                        (point) property nil (point-max))
                       (point-max)))))
    (nreverse positions)))

(defun netease-radio--goto-neighbor-start (direction property label)
  "Move to neighboring PROPERTY start in DIRECTION for LABEL."
  (let* ((positions (netease-radio--start-property-positions property))
         (target (pcase direction
                   ('next
                    (seq-find (lambda (pos)
                                (> pos (point)))
                              positions))
                   ('previous
                    (car (last (seq-take-while
                                (lambda (pos)
                                  (< pos (point)))
                                positions)))))))
    (if target
        (goto-char target)
      (user-error "No %s %s" direction label))))

(defun netease-radio--goto-neighbor-item (direction)
  "Move point to the next track row in DIRECTION."
  (netease-radio--goto-neighbor-start
   direction 'netease-radio-track-start "item"))

(defun netease-radio--goto-neighbor-section (direction)
  "Move point to the next source section in DIRECTION."
  (netease-radio--goto-neighbor-start
   direction 'netease-radio-section-start "section"))

;;;###autoload
(defun netease-radio-next-item ()
  "Move point to the next rendered track or line."
  (interactive)
  (if (eq netease-radio--browser-view 'home)
      (forward-line 1)
    (netease-radio--goto-neighbor-item 'next)))

;;;###autoload
(defun netease-radio-previous-item ()
  "Move point to the previous rendered track or line."
  (interactive)
  (if (eq netease-radio--browser-view 'home)
      (forward-line -1)
    (netease-radio--goto-neighbor-item 'previous)))

;;;###autoload
(defun netease-radio-next-section ()
  "Move point to the next rendered section."
  (interactive)
  (netease-radio--goto-neighbor-section 'next))

;;;###autoload
(defun netease-radio-previous-section ()
  "Move point to the previous rendered section."
  (interactive)
  (netease-radio--goto-neighbor-section 'previous))

;;;###autoload
(defun netease-radio-open-at-point ()
  "Play the track at point."
  (interactive)
  (netease-radio--ensure-loaded)
  (if-let* ((track (netease-radio--track-at-point))
            (source (netease-radio--source-at-point)))
      (progn
        (netease-radio--set-playback-queue (plist-get source :tracks) track)
        (netease-radio--play-track track))
    (if-let* ((button (button-at (point))))
        (push-button button)
      (user-error "No track at point"))))

;;;###autoload
(defun netease-radio-play-source (&optional source)
  "Play the first track from SOURCE or the source at point."
  (interactive)
  (let* ((source (or source (netease-radio--source-at-point)))
         (tracks (and source (plist-get source :tracks))))
    (unless tracks
      (user-error "No source at point"))
    (netease-radio--set-playback-queue tracks (car tracks))
    (netease-radio--play-track (car tracks))))

;;;###autoload
(defun netease-radio-more ()
  "Open the source or track at point."
  (interactive)
  (netease-radio-open-at-point))

;;;###autoload
(defun netease-radio-refresh ()
  "Refresh the current browser view."
  (interactive)
  (cond
   ((and (eq netease-radio--browser-view 'search)
         netease-radio--last-search-query)
    (netease-radio-search netease-radio--last-search-query))
   ((eq netease-radio--browser-view 'discover)
    (netease-radio--refresh-discover))
   (t
    (netease-radio--render))))

(defun netease-radio--now-playing-text-width ()
  "Return now-playing text width in columns."
  (let* ((frame (if (frame-live-p netease-radio--frame)
                    netease-radio--frame
                  (selected-frame)))
         (char-width (max 1 (frame-char-width frame)))
         (cover-columns (ceiling (/ (float netease-radio-cover-size) char-width)))
         (controls-width
          (string-width
           (string-join (mapcar #'car (netease-radio--now-playing-controls)) "  "))))
    (max controls-width
         (+ cover-columns (* 2 netease-radio-child-frame-horizontal-padding)))))

(defun netease-radio--now-playing-frame ()
  "Return the live now-playing frame, or the selected frame."
  (if (frame-live-p netease-radio--frame)
      netease-radio--frame
    (selected-frame)))

(defun netease-radio--now-playing-desired-pixel-width (frame)
  "Return compact desired now-playing FRAME width in pixels."
  (* (netease-radio--now-playing-text-width)
     (max 1 (frame-char-width frame))))

(defun netease-radio--now-playing-text-pixel-width ()
  "Return now-playing text width in pixels."
  (netease-radio--now-playing-desired-pixel-width
   (netease-radio--now-playing-frame)))

(defun netease-radio--insert-pixel-space (pixels)
  "Insert a horizontal display space of PIXELS."
  (when (> pixels 0)
    (insert (propertize " " 'display `(space :width (,pixels))))))

(defun netease-radio--insert-centered-now-playing-line (text &optional face width)
  "Insert TEXT centered in the now-playing view."
  (let* ((width (or width (netease-radio--now-playing-text-width)))
         (text (truncate-string-to-width (or text "") width nil nil t))
         (padding (max 0 (/ (- width (string-width text)) 2))))
    (insert (make-string padding ?\s))
    (insert (if face (propertize text 'face face) text))
    (insert "\n")))

(defun netease-radio--map-track-list (tracks track-id function)
  "Return TRACKS with FUNCTION applied to the track matching TRACK-ID."
  (mapcar (lambda (track)
            (if (equal (plist-get track :id) track-id)
                (funcall function track)
              track))
          tracks))

(defun netease-radio--update-known-track (track-id function)
  "Apply FUNCTION to known track TRACK-ID in player, queue, and state."
  (when-let* ((current (plist-get netease-radio--player :current-track))
              ((equal (plist-get current :id) track-id)))
    (netease-radio--player-set :current-track (funcall function current)))
  (when-let* ((queue (plist-get netease-radio--player :queue)))
    (netease-radio--player-set
     :queue (netease-radio--map-track-list queue track-id function)))
  (netease-radio--state-set
   :sources
   (mapcar (lambda (source)
             (plist-put (copy-sequence source)
                        :tracks
                        (netease-radio--map-track-list
                         (or (plist-get source :tracks) nil)
                         track-id
                         function)))
           (netease-radio--sources))))

(defun netease-radio--cover-url (track)
  "Return TRACK's cover image URL, or nil."
  (let ((url (plist-get track :thumbnail-url)))
    (and (stringp url)
         (not (string-empty-p url))
         url)))

(defun netease-radio--song-detail-url (netease-id)
  "Return NetEase song detail URL for NETEASE-ID."
  (concat "https://music.163.com/api/song/detail/?"
          (url-build-query-string
           `(("ids" ,(format "[%s]" (if (listp netease-id)
                                        (string-join netease-id ",")
                                      netease-id)))))))

(defun netease-radio--song-detail-artist-label (song)
  "Return artist label from NetEase song detail SONG."
  (netease-radio--artists-label
   (netease-radio--json-first song 'artists 'ar)))

(defun netease-radio--batch-fill-metadata-finish (status _tracks)
  "Finish batch metadata request for TRACKS."
  (unwind-protect
      (condition-case err
          (let ((error-data (plist-get status :error)))
            (if error-data
                (message "Metadata fetch failed: %s" error-data)
              (let* ((json (netease-radio--parse-url-json-buffer))
                     (songs (netease-radio--json-get json 'songs)))
                (dolist (song songs)
                  (let* ((id (format "%s" (netease-radio--json-get song 'id)))
                         (track-id (concat "netease:" id))
                         (album (netease-radio--json-first song 'album 'al))
                         (artist (netease-radio--song-detail-artist-label song))
                         (cover-url (netease-radio--json-first album 'picUrl 'pic_url))
                         (title (netease-radio--json-first song 'name 'title))
                         (duration (netease-radio--json-number
                                    (netease-radio--json-first song 'duration 'dt)
                                    1000)))
                    (netease-radio--update-known-track
                     track-id
                     (lambda (track)
                       (let ((copy (copy-sequence track)))
                         (when artist
                           (plist-put copy :artist artist))
                         (when (and title (not (plist-get copy :title)))
                           (plist-put copy :title title))
                         (when album
                           (plist-put copy :album (netease-radio--json-get album 'name)))
                         (when duration
                           (plist-put copy :duration duration))
                         (when cover-url
                           (plist-put copy :thumbnail-url cover-url))
                         copy)))))
                (netease-radio--save)
                (netease-radio--render))))
        (error
         (message "Metadata fetch failed: %s" (error-message-string err))))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun netease-radio--batch-fill-metadata (tracks)
  "Batch-fill missing metadata for TRACKS from NetEase song detail API."
  (let* ((missing (seq-filter (lambda (track)
                                (and (plist-get track :netease-id)
                                     (not (stringp (plist-get track :artist)))))
                              tracks)))
    (when missing
      (let* ((netease-ids (delq nil (mapcar (lambda (track)
                                              (plist-get track :netease-id))
                                            missing)))
             (url (netease-radio--song-detail-url netease-ids)))
        (let ((url-request-extra-headers
               '(("User-Agent" . "Mozilla/5.0 netease-radio")
                 ("Referer" . "https://music.163.com/"))))
          (url-retrieve url
                        #'netease-radio--batch-fill-metadata-finish
                        (list tracks)
                        t
                        t))))))

(defun netease-radio--song-detail-cover-url (json)
  "Return cover URL from NetEase song detail JSON."
  (let* ((songs (netease-radio--json-get json 'songs))
         (song (car-safe songs))
         (album (netease-radio--json-first song 'album 'al)))
    (netease-radio--json-first album 'picUrl 'pic_url)))

(defun netease-radio--cover-detail-finish (status netease-id track-id)
  "Finish cover detail request for NETEASE-ID and TRACK-ID.
STATUS is the `url-retrieve' callback status plist."
  (unwind-protect
      (condition-case err
          (let ((error-data (plist-get status :error)))
            (if error-data
                (progn
                  (puthash netease-id t netease-radio--cover-detail-failed-ids)
                  (message "Cover metadata failed: %s" error-data))
              (let* ((json (netease-radio--parse-url-json-buffer))
                     (cover-url (netease-radio--song-detail-cover-url json)))
                (if (and (stringp cover-url)
                         (not (string-empty-p cover-url)))
                    (progn
                      (netease-radio--update-known-track
                       track-id
                       (lambda (track)
                         (plist-put (copy-sequence track)
                                    :thumbnail-url cover-url)))
                      (netease-radio--save)
                      (netease-radio--render))
                  (puthash netease-id t netease-radio--cover-detail-failed-ids)))))
        (error
         (puthash netease-id t netease-radio--cover-detail-failed-ids)
         (message "Cover metadata failed: %s" (error-message-string err))))
    (remhash netease-id netease-radio--cover-detail-requests)
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun netease-radio--queue-cover-detail (track)
  "Request cover metadata for TRACK when possible."
  (when-let* ((netease-id (plist-get track :netease-id))
              ((stringp netease-id))
              ((not (string-empty-p netease-id)))
              ((not (gethash netease-id netease-radio--cover-detail-requests)))
              ((not (gethash netease-id netease-radio--cover-detail-failed-ids))))
    (puthash netease-id t netease-radio--cover-detail-requests)
    (let ((url-request-extra-headers
           '(("User-Agent" . "Mozilla/5.0 netease-radio")
             ("Referer" . "https://music.163.com/"))))
      (url-retrieve (netease-radio--song-detail-url netease-id)
                    #'netease-radio--cover-detail-finish
                    (list netease-id (plist-get track :id))
                    t
                    t))
    t))

(defun netease-radio--cover-cache-extension (url)
  "Return a safe image file extension inferred from URL."
  (let* ((parsed (url-generic-parse-url url))
         (path (or (url-filename parsed) ""))
         (clean-path (car (split-string path "[?#]")))
         (extension (downcase (or (file-name-extension clean-path) ""))))
    (if (member extension '("jpg" "jpeg" "png" "webp" "gif"))
        extension
      "jpg")))

(defun netease-radio--cover-cache-file (url)
  "Return the cached cover file path for URL."
  (expand-file-name
   (format "%s.%s"
           (secure-hash 'sha1 url)
           (netease-radio--cover-cache-extension url))
   netease-radio-cover-cache-directory))

(defun netease-radio--cover-cache-ready-p (file)
  "Return non-nil when FILE is a non-empty cached cover."
  (and (file-regular-p file)
       (> (file-attribute-size (file-attributes file)) 0)))

(defun netease-radio--cover-image (file)
  "Return an Emacs image object for cached cover FILE, or nil."
  (when (and (display-images-p)
             (netease-radio--cover-cache-ready-p file))
    (condition-case nil
        (create-image file nil nil
                      :width netease-radio-cover-size
                      :height netease-radio-cover-size
                      :ascent 'center)
      (error nil))))

(defun netease-radio--cover-download-finish (status url target)
  "Finish asynchronous cover download for URL into TARGET.
STATUS is the `url-retrieve' callback status plist."
  (unwind-protect
      (condition-case err
          (let ((error-data (plist-get status :error)))
            (if error-data
                (progn
                  (puthash url t netease-radio--cover-failed-urls)
                  (message "Cover download failed: %s" error-data))
              (goto-char (point-min))
              (unless (re-search-forward "\r?\n\r?\n" nil t)
                (error "Missing HTTP response body"))
              (make-directory (file-name-directory target) t)
              (write-region (point) (point-max) target nil 'silent)
              (if (netease-radio--cover-cache-ready-p target)
                  (progn
                    (remhash url netease-radio--cover-failed-urls)
                    (netease-radio--render-now-playing))
                (puthash url t netease-radio--cover-failed-urls)
                (when (file-exists-p target)
                  (delete-file target)))))
        (error
         (puthash url t netease-radio--cover-failed-urls)
         (message "Cover download failed: %s" (error-message-string err))))
    (remhash url netease-radio--cover-downloads)
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun netease-radio--queue-cover-download (url target)
  "Download cover URL into TARGET unless already cached or in flight."
  (unless (or (netease-radio--cover-cache-ready-p target)
              (gethash url netease-radio--cover-downloads)
              (gethash url netease-radio--cover-failed-urls))
    (puthash url t netease-radio--cover-downloads)
    (let ((url-request-extra-headers
           '(("User-Agent" . "Mozilla/5.0 netease-radio")
             ("Referer" . "https://music.163.com/"))))
      (url-retrieve url
                    #'netease-radio--cover-download-finish
                    (list url target)
                    t
                    t))))

(defun netease-radio--insert-centered-now-playing-image (image)
  "Insert IMAGE centered in the now-playing view."
  (let* ((frame (if (frame-live-p netease-radio--frame)
                    netease-radio--frame
                  (selected-frame)))
         (char-width (max 1 (frame-char-width frame)))
         (image-columns (ceiling (/ (float netease-radio-cover-size) char-width)))
         (padding (max 0 (/ (- (netease-radio--now-playing-text-width)
                                image-columns)
                             2))))
    (insert (make-string padding ?\s))
    (insert (propertize " " 'display image))
    (insert "\n")))

(defun netease-radio--insert-now-playing-cover (track)
  "Insert TRACK cover image or a placeholder."
  (if-let* ((url (netease-radio--cover-url track)))
      (let* ((file (netease-radio--cover-cache-file url))
             (ready (netease-radio--cover-cache-ready-p file))
             (image (and ready (netease-radio--cover-image file))))
        (cond
         (image
          (netease-radio--insert-centered-now-playing-image image))
         (ready
          (netease-radio--insert-centered-now-playing-line "[cover cached]" 'shadow))
         (t
          (netease-radio--queue-cover-download url file)
          (netease-radio--insert-centered-now-playing-line "[cover loading]" 'shadow))))
    (if (netease-radio--queue-cover-detail track)
        (netease-radio--insert-centered-now-playing-line "[cover loading]" 'shadow)
      (netease-radio--insert-centered-now-playing-line "[cover unavailable]" 'shadow))))

(defun netease-radio--playback-time-label (track)
  "Return a playback time label for TRACK."
  (let ((position (plist-get netease-radio--player :position))
        (duration (or (plist-get netease-radio--player :duration)
                      (plist-get track :duration))))
    (when (or position duration)
      (format "%s / %s"
              (or (netease-radio--format-duration position) "--:--")
              (or (netease-radio--format-duration duration) "--:--")))))

(defun netease-radio--repeat-control ()
  "Return the repeat control button spec."
  (pcase (plist-get netease-radio--player :repeat)
    ('one
     (list (netease-radio--mdicon "nf-md-repeat_once" "1")
           #'netease-radio-cycle-repeat
           "Repeat one"
           'bold))
    ('all
     (list (netease-radio--mdicon "nf-md-repeat" "R")
           #'netease-radio-cycle-repeat
           "Repeat all"
           'bold))
    (_
     (list (netease-radio--mdicon "nf-md-repeat" "R")
           #'netease-radio-cycle-repeat
           "Repeat off"
           'shadow))))

(defun netease-radio--shuffle-control ()
  "Return the shuffle control button spec."
  (if (plist-get netease-radio--player :shuffle)
      (list (netease-radio--mdicon "nf-md-shuffle_variant" "S")
            #'netease-radio-toggle-shuffle
            "Shuffle on"
            'bold)
    (list (netease-radio--mdicon "nf-md-shuffle_variant" "S")
          #'netease-radio-toggle-shuffle
          "Shuffle off"
          'shadow)))

(defun netease-radio--now-playing-controls ()
  "Return now-playing controls as button specs."
  (list
   (netease-radio--repeat-control)
   (list (netease-radio--mdicon "nf-md-skip_previous" "<<")
         #'netease-radio-previous
         "Previous track")
   (list (if (eq (plist-get netease-radio--player :status) 'playing)
             (netease-radio--mdicon "nf-md-pause" "||")
           (netease-radio--mdicon "nf-md-play" ">"))
         #'netease-radio-toggle-pause
         "Play or pause")
   (list (netease-radio--mdicon "nf-md-skip_next" ">>")
         #'netease-radio-next
         "Next track")
   (netease-radio--shuffle-control)))

(defun netease-radio--insert-now-playing-control (icon command help &optional face)
  "Insert a now-playing ICON button running COMMAND with HELP text."
  (insert-text-button (format "%s" icon)
                      'type 'netease-radio-now-playing-button
                      'action (lambda (_button)
                                (call-interactively command))
                      'help-echo help
                      'face (or face 'default)))

(defun netease-radio--insert-now-playing-controls-row (controls separator)
  "Insert now-playing CONTROLS separated by SEPARATOR."
  (cl-loop for (icon command help face) in controls
           for first = t then nil
           unless first do (insert separator)
           do (netease-radio--insert-now-playing-control icon command help face)))

(defun netease-radio--now-playing-controls-key (controls)
  "Return a stable cache key for CONTROLS."
  (mapcar (lambda (control)
            (list (format "%s" (nth 0 control))
                  (nth 3 control)))
          controls))

(defun netease-radio--measure-now-playing-controls-pixels (controls separator)
  "Return live pixel width of CONTROLS separated by SEPARATOR."
  (when-let* ((window (netease-radio--live-root-window netease-radio--frame))
              ((eq (window-buffer window) (current-buffer))))
    (let ((start (point))
          width)
      (unwind-protect
          (progn
            (netease-radio--insert-now-playing-controls-row controls separator)
            (setq width
                  (car-safe
                   (ignore-errors
                     (window-text-pixel-size window start (point))))))
        (delete-region start (point)))
      width)))

(defun netease-radio--now-playing-controls-pixel-width (controls separator)
  "Return cached live pixel width of CONTROLS separated by SEPARATOR."
  (let ((key (netease-radio--now-playing-controls-key controls)))
    (if (and (equal key netease-radio--controls-pixel-width-key)
             (numberp netease-radio--controls-pixel-width-cache))
        netease-radio--controls-pixel-width-cache
      (let ((width (netease-radio--measure-now-playing-controls-pixels
                    controls separator)))
        (when (numberp width)
          (setq netease-radio--controls-pixel-width-key key
                netease-radio--controls-pixel-width-cache width))
        width))))

(defun netease-radio--insert-now-playing-controls ()
  "Insert centered now-playing controls."
  (let* ((separator "  ")
         (controls (netease-radio--now-playing-controls)))
    (if (and (display-graphic-p (netease-radio--now-playing-frame))
             (fboundp 'window-text-pixel-size))
        (let* ((controls-width
                (or (netease-radio--now-playing-controls-pixel-width
                     controls separator)
                    0))
               (padding (max 0 (/ (- (netease-radio--now-playing-text-pixel-width)
                                     controls-width)
                                  2))))
          (netease-radio--insert-pixel-space padding))
      (let* ((controls-width
              (string-width (string-join (mapcar #'car controls) separator)))
             (padding (max 0 (/ (- (netease-radio--now-playing-text-width)
                                  controls-width)
                               2))))
        (insert (make-string padding ?\s))))
    (netease-radio--insert-now-playing-controls-row controls separator)
    (insert "\n")))

(defun netease-radio--render-now-playing ()
  "Render the now-playing buffer when it exists."
  (when-let* ((buffer (get-buffer netease-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (old-point (point))
            (track (netease-radio--current-track)))
        (erase-buffer)
        (if track
            (let ((text-width (netease-radio--now-playing-text-width)))
              (insert netease-radio--now-playing-top-padding)
              (netease-radio--insert-now-playing-cover track)
              (insert netease-radio--now-playing-thin-padding)
              (netease-radio--insert-centered-now-playing-line
               (netease-radio--track-title track)
               'netease-radio-now-playing-title
               text-width)
              (netease-radio--insert-centered-now-playing-line
               (netease-radio--track-artist track)
               'shadow
               text-width)
              (when-let* ((time-label (netease-radio--playback-time-label track)))
                (netease-radio--insert-centered-now-playing-line time-label nil text-width))
              (insert netease-radio--now-playing-thin-padding)
              (netease-radio--insert-now-playing-controls)
              (insert netease-radio--now-playing-bottom-padding))
          (insert "No track\n"))
        (goto-char (min (max old-point (point-min)) (point-max)))
        (when (eobp)
          (goto-char (point-min)))))
    (netease-radio--sync-now-playing-frame buffer)))

(defun netease-radio--apply-child-frame-border-face (frame)
  "Apply child-frame border styling to FRAME."
  (let ((background (face-background 'netease-radio-child-frame-border frame t)))
    (set-face-background 'child-frame-border
                         (or background "gray50")
                         frame)))

(defun netease-radio--live-root-window (frame)
  "Return FRAME's live root window, or nil."
  (when (frame-live-p frame)
    (condition-case nil
        (let ((window (frame-root-window frame)))
          (and (window-live-p window) window))
      (error nil))))

(defun netease-radio--discard-now-playing-frame ()
  "Forget the current now-playing child frame."
  (when (frame-live-p netease-radio--frame)
    (ignore-errors
      (delete-frame netease-radio--frame)))
  (setq netease-radio--frame nil))

(defun netease-radio--parent-window-inside-pixel-edges (parent)
  "Return usable pixel edges of PARENT's root window."
  (condition-case nil
      (cond
       ((netease-radio--live-root-window parent)
        (let ((window (netease-radio--live-root-window parent)))
          (if (fboundp 'window-inside-pixel-edges)
              (window-inside-pixel-edges window)
            (window-pixel-edges window))))
       ((frame-live-p parent)
        (list 0 0 (frame-pixel-width parent) (frame-pixel-height parent)))
       (t
        '(0 0 1 1)))
    (error
     '(0 0 1 1))))

(defun netease-radio--child-frame-margins (parent)
  "Return child-frame margins for PARENT as (X . Y) pixels."
  (condition-case nil
      (if (frame-live-p parent)
          (cons (* 2 (frame-char-width parent))
                (* 2 (frame-char-height parent)))
        '(0 . 0))
    (error '(0 . 0))))

(defun netease-radio--now-playing-min-pixel-size (frame)
  "Return minimum now-playing child FRAME size in pixels."
  (let ((line-height (max 1 (frame-char-height frame))))
    (cons (netease-radio--now-playing-desired-pixel-width frame)
          (+ netease-radio-cover-size (* 5 line-height)))))

(defun netease-radio--now-playing-content-pixel-size (frame buffer)
  "Return rendered content size for BUFFER in child FRAME, or nil."
  (when-let* ((window (netease-radio--live-root-window frame)))
    (with-current-buffer buffer
      (ignore-errors
        (window-text-pixel-size window (point-min) (point-max))))))

(defun netease-radio--last-content-position (buffer)
  "Return the last non-whitespace content position in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-max))
      (skip-chars-backward " \t\n\r")
      (max (point-min) (point)))))

(defun netease-radio--content-visible-p (frame buffer)
  "Return non-nil when BUFFER's final content is visible in FRAME."
  (when-let* ((window (netease-radio--live-root-window frame)))
    (with-current-buffer buffer
      (ignore-errors
        (pos-visible-in-window-p
         (netease-radio--last-content-position buffer)
         window
         nil)))))

(defun netease-radio--resize-now-playing-frame (frame buffer)
  "Resize child FRAME so BUFFER's cover and controls are fully visible."
  (when (netease-radio--live-root-window frame)
    (condition-case nil
        (let* ((minimum (netease-radio--now-playing-min-pixel-size frame))
               (measured (netease-radio--now-playing-content-pixel-size frame buffer))
               (padding (max 2 (/ (frame-char-height frame) 3)))
               (width (car minimum))
               (height (max (cdr minimum)
                            (if measured (+ (cdr measured) padding) 0))))
          (when-let* ((parent (frame-parent frame)))
            (pcase-let* ((`(,left ,top ,right ,bottom)
                          (netease-radio--parent-window-inside-pixel-edges parent))
                         (`(,x-margin . ,y-margin)
                          (netease-radio--child-frame-margins parent)))
              (setq width (min width (max 1 (- right left (* 2 x-margin)))))
              (setq height (min height (max 1 (- bottom top (* 2 y-margin)))))))
          (let ((window (netease-radio--live-root-window frame)))
            (unless (and window
                         (= width (window-body-width window t))
                         (= height (window-body-height window t))
                         (netease-radio--content-visible-p frame buffer))
              (set-frame-size frame width height t)
              (redisplay)))
          (let ((tries 0)
                (line-height (max 1 (frame-char-height frame))))
            (while (and (< tries 8)
                        (not (netease-radio--content-visible-p frame buffer)))
              (setq tries (1+ tries)
                    height (+ height line-height))
              (set-frame-size frame width height t)
              (redisplay)))
          t)
      (error nil))))

(defun netease-radio--position-frame (frame)
  "Position child FRAME at the lower right of its parent."
  (condition-case nil
      (when (netease-radio--live-root-window frame)
        (when-let* ((parent (frame-parent frame)))
          (pcase-let* ((`(,_left ,_top ,right ,bottom)
                        (netease-radio--parent-window-inside-pixel-edges parent))
                       (`(,x-margin . ,y-margin)
                        (netease-radio--child-frame-margins parent)))
            (let* ((x (max 0 (- right
                                  (frame-pixel-width frame)
                                  x-margin)))
                   (y (max 0 (- bottom
                                  (frame-pixel-height frame)
                                  y-margin)))
                   (current (frame-position frame)))
              (unless (and (equal (car current) x)
                           (equal (cdr current) y))
                (set-frame-position frame x y))))))
    (error nil)))

(defun netease-radio--sync-now-playing-frame (buffer)
  "Synchronize live child-frame size and position for BUFFER."
  (when (and (eq netease-radio-display-style 'child-frame)
             (frame-live-p netease-radio--frame))
    (condition-case nil
        (if-let* ((window (netease-radio--live-root-window netease-radio--frame)))
            (progn
              (with-current-buffer buffer
                (set-window-start window (point-min) t))
              (unless (netease-radio--resize-now-playing-frame
                       netease-radio--frame buffer)
                (netease-radio--discard-now-playing-frame))
              (when (frame-live-p netease-radio--frame)
                (netease-radio--position-frame netease-radio--frame)))
          (netease-radio--discard-now-playing-frame))
      (error
       (netease-radio--discard-now-playing-frame)))))

(defun netease-radio--ensure-frame (buffer)
  "Return a child frame showing now-playing BUFFER."
  (unless (frame-live-p netease-radio--frame)
    (setq netease-radio--frame
          (condition-case nil
              (make-frame
               `((parent-frame . ,(selected-frame))
                 (minibuffer . nil)
                 (undecorated . t)
                 (skip-taskbar . t)
                 (no-other-frame . t)
                 (unsplittable . t)
                 (left-fringe . 0)
                 (right-fringe . 0)
                 (vertical-scroll-bars . nil)
                 (horizontal-scroll-bars . nil)
                 (scroll-bar-width . 0)
                 (scroll-bar-height . 0)
                 (right-divider-width . 0)
                 (bottom-divider-width . 0)
                 (menu-bar-lines . 0)
                 (tool-bar-lines . 0)
                 (tab-bar-lines . 0)
                 (internal-border-width . 0)
                 (child-frame-border-width . 1)
                 (no-focus-on-map . t)
                 (visibility . nil)))
            (error nil))))
  (condition-case nil
      (if-let* ((window (netease-radio--live-root-window netease-radio--frame)))
          (progn
            (netease-radio--apply-child-frame-border-face netease-radio--frame)
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (set-window-start window (point-min) t))
            (set-window-dedicated-p window t)
            (set-window-fringes window 0 0 nil t)
            (set-window-margins window 0 0)
            (set-window-scroll-bars window 0 nil 0 nil t)
            (netease-radio--sync-now-playing-frame buffer)
            netease-radio--frame)
        (netease-radio--discard-now-playing-frame)
        nil)
    (error
     (netease-radio--discard-now-playing-frame)
     nil)))

(defun netease-radio--show-now-playing (&optional focus)
  "Show the now-playing view.
When FOCUS is non-nil, focus the now-playing child frame."
  (let ((buffer (netease-radio--now-playing-buffer)))
    (netease-radio--render-now-playing)
    (if (and (eq netease-radio-display-style 'child-frame)
             (display-graphic-p))
        (let ((selected-frame (selected-frame))
              (selected-window (selected-window))
              (frame (netease-radio--ensure-frame buffer)))
          (if (not (frame-live-p frame))
              (pop-to-buffer buffer)
            (unwind-protect
                (progn
                  ;; Re-render with a live child frame so icon controls can be
                  ;; centered using their actual window pixel width.
                  (netease-radio--render-now-playing)
                  (unless (frame-visible-p frame)
                    (make-frame-visible frame))
                  (when focus
                    (select-frame-set-input-focus frame)))
              (unless focus
                (when (frame-live-p selected-frame)
                  (select-frame selected-frame)
                  (when (window-live-p selected-window)
                    (select-window selected-window)))))))
      (pop-to-buffer buffer))))

;;;###autoload
(defun netease-radio-now-playing ()
  "Show the NetEase now-playing view."
  (interactive)
  (netease-radio--ensure-loaded)
  (netease-radio--show-now-playing t))

;;;###autoload
(defun netease-radio-hide-now-playing ()
  "Hide the NetEase now-playing view."
  (interactive)
  (if (frame-live-p netease-radio--frame)
      (delete-frame netease-radio--frame)
    (quit-window))
  (setq netease-radio--frame nil))

;;;###autoload
(defun netease-radio-hide-browser ()
  "Hide the NetEase browser window."
  (interactive)
  (quit-window))

;;;###autoload
(defun netease-radio ()
  "Open the NetEase Cloud Music browser."
  (interactive)
  (netease-radio--ensure-loaded)
  (let ((buffer (netease-radio--buffer)))
    (pop-to-buffer buffer)
    (netease-radio--render)))

;;;###autoload
(defun netease-radio-doctor ()
  "Show a setup diagnostic report for netease-radio."
  (interactive)
  (let ((buffer (get-buffer-create netease-radio--doctor-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (special-mode)
        (erase-buffer)
        (insert "netease-radio doctor\n\n")
        (dolist (program `(("mpv" . ,netease-radio-mpv-program)
                           ("yt-dlp" . ,netease-radio-yt-dlp-program)))
          (pcase-let ((`(,label . ,command) program))
            (insert (format "%-8s %s\n"
                            label
                            (or (and (stringp command)
                                     (if (file-name-absolute-p command)
                                         (and (file-executable-p command) command)
                                       (executable-find command)))
                                "missing")))))
        (insert (format "\nState: %s\n" netease-radio-state-file))
        (insert (format "Data:  %s\n" netease-radio-data-directory))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun netease-radio-login (&optional output)
  "Open Chrome to log into NetEase Cloud Music and save cookies.

This runs the helper Python script (Playwright) that opens Chrome,
waits for you to sign in to music.163.com, then saves the session
cookies in Netscape format.

With a prefix argument (\\[universal-argument]), you can choose a
custom output path for the cookies file.  Otherwise cookies are
saved to `netease-radio-data-directory'/cookies.txt.

On success, `netease-radio-yt-dlp-cookies' is automatically set to
the output path if it was previously unset."
  (interactive
   (list (when current-prefix-arg
           (read-file-name "Cookies output file: "
                           (expand-file-name "cookies.txt"
                                             netease-radio-data-directory)))))
  (unless netease-radio--helper-directory
    (error (concat "Cannot locate the netease-radio helper directory.  "
                   "Make sure netease-radio.el is installed as a regular file.")))
  (let* ((script (expand-file-name "netease_cookies.py"
                                   netease-radio--helper-directory))
         (venv-python (expand-file-name ".venv/bin/python"
                                        netease-radio--helper-directory))
         (python-cmd (if (file-executable-p venv-python) venv-python "python3"))
         (default-output (expand-file-name "cookies.txt"
                                           netease-radio-data-directory))
         (output-file (or output default-output)))
    (unless (file-exists-p script)
      (error "Helper script not found: %s" script))
    (message "Launching NetEase login helper (Chrome will open)...")
    (make-process
     :name "netease-radio-login"
     :buffer (generate-new-buffer " *netease-radio-login*")
     :command (list python-cmd script "-o" output-file)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((exit-code (process-exit-status proc)))
           (if (eq exit-code 0)
               (progn
                 (message "netease-radio: login complete, cookies saved to %s"
                          output-file)
                 (unless netease-radio-yt-dlp-cookies
                   (setq netease-radio-yt-dlp-cookies output-file)
                   (message "netease-radio: yt-dlp-cookies set to %s"
                            output-file)))
             (message (concat "netease-radio: login helper exited with code %d "
                              "(see buffer %s for details)")
                      exit-code
                      (buffer-name (process-buffer proc))))))))))

(provide 'netease-radio)

;;; netease-radio.el ends here
