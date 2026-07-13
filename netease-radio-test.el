;;; netease-radio-test.el --- Tests for netease-radio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'netease-radio)

(ert-deftest netease-radio-test-song-url ()
  (should (equal (netease-radio--song-url 123)
                 "https://music.163.com/song?id=123")))

(ert-deftest netease-radio-test-search-source-from-json ()
  (let* ((json '(("result"
                  ("songs"
                   . ((("id" . 123)
                       ("name" . "Song A")
                       ("artists" . ((("name" . "Artist A"))
                                     (("name" . "Artist B"))))
                       ("album" ("name" . "Album A")
                                ("picUrl" . "https://example.invalid/a.jpg"))
                       ("duration" . 125000)))))))
         (source (netease-radio--search-source-from-json "hello" json))
         (track (car (plist-get source :tracks))))
    (should (equal (plist-get source :id) "search:hello"))
    (should (equal (plist-get track :id) "netease:123"))
    (should (equal (plist-get track :title) "Song A"))
    (should (equal (plist-get track :artist) "Artist A / Artist B"))
    (should (equal (plist-get track :album) "Album A"))
    (should (equal (plist-get track :duration) 125.0))
    (should (equal (plist-get track :url)
                   "https://music.163.com/song?id=123"))
    (should (equal (plist-get track :thumbnail-url)
                   "https://example.invalid/a.jpg"))))

(ert-deftest netease-radio-test-search-source-from-modern-json ()
  (let* ((json '(("result"
                  ("songs"
                   . ((("id" . 123)
                       ("name" . "Song A")
                       ("ar" . ((("name" . "Artist A"))))
                       ("al" ("name" . "Album A")
                             ("picUrl" . "https://example.invalid/a.jpg"))
                       ("dt" . 125000)))))))
         (source (netease-radio--search-source-from-json "hello" json))
         (track (car (plist-get source :tracks))))
    (should (equal (plist-get track :artist) "Artist A"))
    (should (equal (plist-get track :album) "Album A"))
    (should (equal (plist-get track :duration) 125.0))
    (should (equal (plist-get track :thumbnail-url)
                   "https://example.invalid/a.jpg"))))

(ert-deftest netease-radio-test-discover-recommended-items-from-json ()
  (let* ((json '(("result"
                  . ((("id" . 691394551)
                      ("name" . "Discovery A")
                      ("trackCount" . 42)
                      ("playCount" . 123456))
                     (("name" . "Missing ID"))))))
         (items (netease-radio--discover-recommended-items-from-json json))
         (item (car items)))
    (should (= (length items) 1))
    (should (equal (plist-get item :id) "691394551"))
    (should (eq (plist-get item :kind) 'playlist))
    (should (equal (plist-get item :name) "Discovery A"))
    (should (equal (plist-get item :url)
                   "https://music.163.com/#/playlist?id=691394551"))
    (should (equal (plist-get item :subtitle) "42 tracks"))
    (should (eq (plist-get item :section) 'recommended))))

(ert-deftest netease-radio-test-discover-toplist-items-from-json ()
  (let* ((json '(("list"
                  . ((("id" . 3779629)
                      ("name" . "Cloud Music Top")
                      ("updateFrequency" . "Daily")
                      ("trackCount" . 100))
                     (("name" . "Missing ID"))))))
         (items (netease-radio--discover-toplist-items-from-json json))
         (item (car items)))
    (should (= (length items) 1))
    (should (equal (plist-get item :id) "3779629"))
    (should (eq (plist-get item :kind) 'playlist))
    (should (equal (plist-get item :name) "Cloud Music Top"))
    (should (equal (plist-get item :url)
                   "https://music.163.com/#/playlist?id=3779629"))
    (should (equal (plist-get item :subtitle) "Daily"))
    (should (eq (plist-get item :section) 'toplist))))

(ert-deftest netease-radio-test-search-finish-url-callback-order ()
  (let ((netease-radio--search-buffer nil)
        (netease-radio--loading-message "Searching...")
        captured-source)
    (with-temp-buffer
      (insert "HTTP/1.1 200 OK\n\n"
              "{\"result\":{\"songs\":[{\"id\":123,\"name\":\"Song A\","
              "\"artists\":[{\"name\":\"Artist A\"}],"
              "\"album\":{\"name\":\"Album A\"},\"duration\":125000}]}}")
      (goto-char (point-min))
      (cl-letf (((symbol-function #'netease-radio--put-source)
                 (lambda (source)
                   (setq captured-source source)))
                ((symbol-function #'netease-radio--save) #'ignore)
                ((symbol-function #'netease-radio--render) #'ignore)
                ((symbol-function #'message) #'ignore))
        (netease-radio--search-finish '(:peer "example.invalid") "hello")))
    (should (equal (plist-get captured-source :id) "search:hello"))
    (should (equal (plist-get (car (plist-get captured-source :tracks)) :id)
                   "netease:123"))))

(ert-deftest netease-radio-test-track-from-ytdlp-json ()
  (let* ((json '(("id" . "456")
                 ("title" . "Imported Song")
                 ("artist" . "Imported Artist")
                 ("album" . "Imported Album")
                 ("duration" . 61)
                 ("webpage_url" . "https://music.163.com/song?id=456")))
         (track (netease-radio--track-from-ytdlp-json json "fallback")))
    (should (equal (plist-get track :id) "netease:456"))
    (should (equal (plist-get track :title) "Imported Song"))
    (should (equal (plist-get track :artist) "Imported Artist"))
    (should (equal (plist-get track :duration) 61))
    (should (equal (netease-radio--track-label track)
                   "Imported Song - Imported Artist - Imported Album"))))

(ert-deftest netease-radio-test-put-source-replaces-existing ()
  (let ((netease-radio--state (netease-radio--make-state)))
    (netease-radio--put-source '(:id "x" :title "Old" :tracks nil))
    (netease-radio--put-source '(:id "x" :title "New" :tracks nil))
    (should (= (length (netease-radio--sources)) 1))
    (should (equal (plist-get (car (netease-radio--sources)) :title) "New"))))

(ert-deftest netease-radio-test-render-browser-source-section ()
  (let ((netease-radio--state
         (netease-radio--make-state
          :sources '((:id "search:test"
                      :title "Search: test"
                      :tracks ((:id "netease:1"
                                :title "Song"
                                :artist "Artist"
                                :url "https://music.163.com/song?id=1"))))))
        (netease-radio--player (netease-radio--make-player))
        (netease-radio--browser-view 'search))
    (with-current-buffer (get-buffer-create netease-radio--buffer-name)
      (unwind-protect
          (progn
            (netease-radio-mode)
            (netease-radio--render-browser)
            (goto-char (point-min))
            (search-forward "Search: test")
            (should (get-text-property (match-beginning 0)
                                       'netease-radio-section))
            (search-forward "Artist")
            (should (get-text-property (match-beginning 0)
                                       'netease-radio-track)))
        (kill-buffer (current-buffer))))))

(ert-deftest netease-radio-test-browser-j-k-move-between-track-starts ()
  (let ((netease-radio--state
         (netease-radio--make-state
          :sources '((:id "search:test"
                      :title "Search: test"
                      :tracks ((:id "netease:1"
                                :title "Song A"
                                :artist "Artist A")
                               (:id "netease:2"
                                :title "Song B"
                                :artist "Artist B")
                               (:id "netease:3"
                                :title "Song C"
                                :artist "Artist C"))))))
        (netease-radio--player (netease-radio--make-player))
        (netease-radio--browser-view 'search))
    (with-current-buffer (get-buffer-create netease-radio--buffer-name)
      (unwind-protect
          (progn
            (netease-radio-mode)
            (netease-radio--render-browser)
            (goto-char (point-min))
            (search-forward "Song A")
            (netease-radio-next-item)
            (should (looking-at-p "   2\\. Song B"))
            (netease-radio-previous-item)
            (should (looking-at-p "   1\\. Song A")))
        (kill-buffer (current-buffer))))))

(ert-deftest netease-radio-test-render-now-playing-controls ()
  (let ((netease-radio--player
         (netease-radio--make-player
          :status 'playing
          :current-track '(:id "netease:1"
                           :title "Song"
                           :artist "Artist"
                           :duration 90))))
    (with-current-buffer (get-buffer-create netease-radio--now-playing-buffer-name)
      (unwind-protect
          (progn
            (netease-radio--now-playing-mode)
            (netease-radio--render-now-playing)
            (goto-char (point-min))
            (search-forward "Song")
            (search-forward "Artist")
            (should (next-button (point-min) (point-max))))
        (kill-buffer (current-buffer))))))

(ert-deftest netease-radio-test-render-now-playing-cover-from-cache ()
  (let* ((url "https://example.invalid/cover.jpg")
         (temp-dir (make-temp-file "netease-radio-cover-" t))
         (netease-radio-cover-cache-directory temp-dir)
         (netease-radio--cover-downloads (make-hash-table :test #'equal))
         (netease-radio--cover-failed-urls (make-hash-table :test #'equal))
         (netease-radio--player
          (netease-radio--make-player
           :status 'playing
           :current-track `(:id "netease:1"
                            :title "Song"
                            :artist "Artist"
                            :thumbnail-url ,url)))
         (cover-file (netease-radio--cover-cache-file url))
         found-image)
    (unwind-protect
        (progn
          (make-directory (file-name-directory cover-file) t)
          (with-temp-file cover-file
            (insert "fake image bytes"))
          (cl-letf (((symbol-function #'display-images-p)
                     (lambda (&optional _display) t))
                    ((symbol-function #'create-image)
                     (lambda (&rest _args) 'netease-radio-test-image)))
            (with-current-buffer (get-buffer-create netease-radio--now-playing-buffer-name)
              (unwind-protect
                  (progn
                    (netease-radio--now-playing-mode)
                    (netease-radio--render-now-playing)
                    (goto-char (point-min))
                    (while (and (not found-image) (< (point) (point-max)))
                      (when (eq (get-text-property (point) 'display)
                                'netease-radio-test-image)
                        (setq found-image t))
                      (goto-char (or (next-single-property-change
                                      (point) 'display nil (point-max))
                                     (point-max))))
                    (should found-image))
                (kill-buffer (current-buffer))))))
      (delete-directory temp-dir t))))

(ert-deftest netease-radio-test-sync-now-playing-frame-discards-dead-window ()
  (let ((netease-radio-display-style 'child-frame)
        (netease-radio--frame 'fake-frame))
    (cl-letf (((symbol-function #'frame-live-p)
               (lambda (frame)
                 (eq frame 'fake-frame)))
              ((symbol-function #'frame-root-window)
               (lambda (_frame)
                 (error "not a live window")))
              ((symbol-function #'delete-frame)
               #'ignore))
      (with-temp-buffer
        (netease-radio--sync-now-playing-frame (current-buffer))))
    (should (null netease-radio--frame))))

(ert-deftest netease-radio-test-mpv-filter-swallows-ui-errors ()
  (let ((pending-value nil)
        (netease-radio--player (netease-radio--make-player)))
    (cl-letf (((symbol-function #'netease-radio--current-mpv-ipc-p)
               (lambda (_process) t))
              ((symbol-function #'netease-radio--mpv-dispatch)
               (lambda (&rest _args)
                 (error "not a live window")))
              ((symbol-function #'process-get)
               (lambda (_process property)
                 (and (eq property 'pending) pending-value)))
              ((symbol-function #'process-put)
               (lambda (_process property value)
                 (when (eq property 'pending)
                   (setq pending-value value)))))
      (netease-radio--mpv-filter 'fake-process "{\"event\":\"x\"}\n")
      (should (equal pending-value "")))))

(ert-deftest netease-radio-test-cover-detail-fills-missing-thumbnail ()
  (let* ((netease-radio--cover-detail-requests (make-hash-table :test #'equal))
         (netease-radio--cover-detail-failed-ids (make-hash-table :test #'equal))
         (netease-radio--state
          (netease-radio--make-state
           :sources '((:id "search:test"
                       :tracks ((:id "netease:123"
                                 :netease-id "123"
                                 :title "Song"))))))
         (netease-radio--player
          (netease-radio--make-player
           :current-track '(:id "netease:123"
                            :netease-id "123"
                            :title "Song")))
         (buffer (generate-new-buffer " *netease-radio-cover-detail-test*")))
    (unwind-protect
        (progn
          (puthash "123" t netease-radio--cover-detail-requests)
          (with-current-buffer buffer
            (insert "HTTP/1.1 200 OK\n\n"
                    "{\"songs\":[{\"id\":123,\"al\":{\"picUrl\":\""
                    "https://example.invalid/detail.jpg\"}}]}")
            (goto-char (point-min))
            (cl-letf (((symbol-function #'netease-radio--save) #'ignore)
                      ((symbol-function #'netease-radio--render) #'ignore))
              (netease-radio--cover-detail-finish nil "123" "netease:123")))
          (should (equal (plist-get (plist-get netease-radio--player :current-track)
                                    :thumbnail-url)
                         "https://example.invalid/detail.jpg"))
          (should (equal (plist-get (car (plist-get (car (netease-radio--sources))
                                                    :tracks))
                                    :thumbnail-url)
                         "https://example.invalid/detail.jpg")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest netease-radio-test-normalize-url-strips-hash ()
  (should (equal (netease-radio--normalize-url
                  "https://music.163.com/#/playlist?id=691394551")
                 "https://music.163.com/playlist?id=691394551"))
  (should (equal (netease-radio--normalize-url
                  "https://music.163.com/song?id=123")
                 "https://music.163.com/song?id=123")))

(ert-deftest netease-radio-test-url-playlist-p ()
  (should (netease-radio--url-playlist-p
           "https://music.163.com/playlist?id=691394551"))
  (should (netease-radio--url-playlist-p
           "https://music.163.com/album?id=123"))
  (should (not (netease-radio--url-playlist-p
                "https://music.163.com/song?id=123"))))

(ert-deftest netease-radio-test-url-source-from-playlist-json ()
  (let* ((json (list (cons "id" "691394551")
                    (cons "title" "My Playlist")
                    (cons "entries"
                          (list (list (cons "id" "1")
                                      (cons "title" "Song 1")
                                      (cons "artist" "Art"))
                                (list (cons "id" "2")
                                      (cons "title" "Song 2")
                                      (cons "artist" "Art"))))))
         (url "https://music.163.com/#/playlist?id=691394551")
         (source (netease-radio--url-source-from-json url json)))
    (should (equal (plist-get source :kind) 'playlist))
    (should (equal (plist-get source :title) "My Playlist"))
    (should (= (length (plist-get source :tracks)) 2))))

(ert-deftest netease-radio-test-render-discover-item-at-point ()
  (let ((netease-radio--discover-items
         '(:recommended ((:id "1"
                          :kind playlist
                          :name "Discovery A"
                          :url "https://music.163.com/#/playlist?id=1"
                          :subtitle "42 tracks"
                          :section recommended))
           :toplists nil))
        (netease-radio--browser-view 'discover))
    (with-current-buffer (get-buffer-create netease-radio--buffer-name)
      (unwind-protect
          (progn
            (netease-radio-mode)
            (netease-radio--render-browser)
            (goto-char (point-min))
            (search-forward "Discovery A")
            (should (equal (plist-get (netease-radio--discover-item-at-point)
                                      :id)
                           "1")))
        (kill-buffer (current-buffer))))))

(ert-deftest netease-radio-test-save-discover-item-to-dashboard ()
  (let ((temp-dir (make-temp-file "netease-radio-dashboard-" t))
        (item '(:id "1"
                :kind playlist
                :name "Discovery A"
                :url "https://music.163.com/#/playlist?id=1"
                :section recommended)))
    (unwind-protect
        (let ((netease-radio-data-directory temp-dir))
          (cl-letf (((symbol-function #'netease-radio-home-view) #'ignore)
                    ((symbol-function #'message) #'ignore))
            (netease-radio--save-discover-item item))
          (let ((saved (car (netease-radio--read-dashboard-playlists))))
            (should (equal (plist-get saved :name) "Discovery A"))
            (should (equal (plist-get saved :url)
                           "https://music.163.com/playlist?id=1"))))
      (delete-directory temp-dir t))))

(ert-deftest netease-radio-test-refresh-discover-dispatch ()
  (let ((netease-radio--browser-view 'discover)
        called)
    (cl-letf (((symbol-function #'netease-radio--refresh-discover)
               (lambda () (setq called t)))
              ((symbol-function #'netease-radio--render)
               (lambda () (setq called 'rendered))))
      (netease-radio-refresh))
    (should (eq called t))))

(provide 'netease-radio-test)

;;; netease-radio-test.el ends here
