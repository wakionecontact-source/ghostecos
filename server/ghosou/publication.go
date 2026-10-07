package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	publicationSessionTTL = 24 * time.Hour
	publicationStageDir   = "./staging"
)

var publicationFilenameNoise = regexp.MustCompile(`(?i)[ _-]+(?:\d{6,}|[a-f0-9]{8,})$`)

// PublicationFields is the user-editable part of a new GhoSou publication.
// It is deliberately separate from Track so the file can be staged and
// checked without creating a public catalog object.
type PublicationFields struct {
	Title           string   `json:"title"`
	Artist          string   `json:"artist"`
	Album           string   `json:"album"`
	Genre           string   `json:"genre"`
	Description     string   `json:"description"`
	Lyrics          string   `json:"lyrics"`
	Kind            string   `json:"kind"`
	Quality         string   `json:"quality"`
	AuthorMode      string   `json:"author_mode"`
	AuthorName      string   `json:"author_name"`
	AnonAuthorID    string   `json:"anon_id"`
	Genres          []string `json:"genres"`
	Tags            []string `json:"tags"`
	Language        string   `json:"language"`
	SourceType      string   `json:"source_type"`
	License         string   `json:"license"`
	LicenseURL      string   `json:"license_url"`
	Visibility      string   `json:"visibility"`
	DownloadAllowed bool     `json:"download_allowed"`
}

type PublicationMatch struct {
	ID      string   `json:"id,omitempty"`
	Title   string   `json:"title,omitempty"`
	Artist  string   `json:"artist,omitempty"`
	Album   string   `json:"album,omitempty"`
	Slug    string   `json:"slug,omitempty"`
	Score   float64  `json:"score,omitempty"`
	Reasons []string `json:"reasons,omitempty"`
	Source  string   `json:"source,omitempty"`
	URL     string   `json:"url,omitempty"`
	Snippet string   `json:"snippet,omitempty"`
}

type PublicationResearch struct {
	Title   string `json:"title,omitempty"`
	URL     string `json:"url,omitempty"`
	Snippet string `json:"snippet,omitempty"`
}

// PublicationAnalysis is persisted with a moderated Track. Public catalog
// responses intentionally omit it; the admin queue receives it explicitly.
type PublicationAnalysis struct {
	GeneratedAt        time.Time             `json:"generated_at"`
	Summary            string                `json:"summary"`
	Dossier            string                `json:"dossier"`
	ModerationRequired bool                  `json:"moderation_required"`
	Warning            string                `json:"warning,omitempty"`
	Similar            []PublicationMatch    `json:"similar,omitempty"`
	Research           []PublicationResearch `json:"research,omitempty"`
	ProposedFields     map[string]string     `json:"proposed_fields,omitempty"`
	ProposedReasons    map[string]string     `json:"proposed_reasons,omitempty"`
	GhoGemAvailable    bool                  `json:"ghogem_available"`
}

type PublicationSession struct {
	ID               string               `json:"id"`
	OwnerID          string               `json:"owner_id"`
	RateKey          string               `json:"rate_key"`
	FilePath         string               `json:"file_path"`
	Filename         string               `json:"filename"`
	Mime             string               `json:"mime"`
	OriginalSize     int64                `json:"original_size"`
	Fields           PublicationFields    `json:"fields"`
	Analysis         *PublicationAnalysis `json:"analysis,omitempty"`
	Stage            string               `json:"stage"`
	Decision         string               `json:"decision,omitempty"`
	PublishedTrackID string               `json:"published_track_id,omitempty"`
	CreatedAt        time.Time            `json:"created_at"`
	UpdatedAt        time.Time            `json:"updated_at"`
}

type publicationAnalyzeRequest struct {
	SessionID string            `json:"session_id"`
	Fields    PublicationFields `json:"fields"`
}

type publicationMatchEnvelope struct {
	Track   map[string]interface{}
	Score   float64
	Reasons []string
	Source  string
}

type adminSoundView struct {
	*PublicTrack
	PublicationAnalysis *PublicationAnalysis `json:"publication_analysis,omitempty"`
}

func adminSoundViewFor(t *Track) *adminSoundView {
	if t == nil {
		return nil
	}
	return &adminSoundView{PublicTrack: publicTrack(t), PublicationAnalysis: t.PublicationAnalysis}
}

func publicationOwnerID(r *http.Request) string {
	if uid := userID(r); uid != "" {
		return "user:" + uid
	}
	return "rate:" + rateKey(r)
}

func requirePublicationAccount(w http.ResponseWriter, r *http.Request) bool {
	if _, ok := resolveSocialAccount(r); ok {
		return true
	}
	publicationJSONError(w, http.StatusUnauthorized, "account required for uploads")
	return false
}

func publicationSessionIDValid(id string) bool {
	if len(id) != 48 {
		return false
	}
	return isLowerHex(id)
}

func publicationSessionPath(id string) string {
	if !publicationSessionIDValid(id) {
		return ""
	}
	return filepath.Join(publicationStageDir, id+".audio")
}

func publicationJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

func publicationStageAllowed(filename, contentType string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	switch ext {
	case ".mp3", ".wav", ".ogg", ".oga", ".opus", ".m4a", ".aac", ".flac", ".aiff", ".aif":
		return true
	}
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(contentType)), "audio/")
}

func clonePublicationFields(f PublicationFields) PublicationFields {
	f.Genres = cloneStrings(f.Genres)
	f.Tags = cloneStrings(f.Tags)
	return f
}

func clonePublicationAnalysis(a *PublicationAnalysis) *PublicationAnalysis {
	if a == nil {
		return nil
	}
	b := *a
	b.Similar = append([]PublicationMatch(nil), a.Similar...)
	b.Research = append([]PublicationResearch(nil), a.Research...)
	if a.ProposedFields != nil {
		b.ProposedFields = map[string]string{}
		for k, v := range a.ProposedFields {
			b.ProposedFields[k] = v
		}
	}
	if a.ProposedReasons != nil {
		b.ProposedReasons = map[string]string{}
		for k, v := range a.ProposedReasons {
			b.ProposedReasons[k] = v
		}
	}
	return &b
}

func clonePublicationSession(s *PublicationSession) *PublicationSession {
	if s == nil {
		return nil
	}
	b := *s
	b.Fields = clonePublicationFields(s.Fields)
	b.Analysis = clonePublicationAnalysis(s.Analysis)
	return &b
}

func publicationSessionForRequest(r *http.Request, id string) (*PublicationSession, error) {
	if !publicationSessionIDValid(id) {
		return nil, fmt.Errorf("invalid publication session")
	}
	owner := publicationOwnerID(r)
	workflowStore.mu.RLock()
	session := clonePublicationSession(workflowStore.publications[id])
	workflowStore.mu.RUnlock()
	if session == nil || session.OwnerID != owner {
		return nil, fmt.Errorf("publication session not found")
	}
	return session, nil
}

func normalizePublicationList(values []string, maxItems, maxBytes int) ([]string, error) {
	joined := strings.Join(values, ",")
	items, ok := parseList(joined, maxItems, maxBytes)
	if !ok {
		return nil, fmt.Errorf("invalid publication list")
	}
	return items, nil
}

func normalizePublicationFields(fields PublicationFields, filename string) (PublicationFields, error) {
	fields.Title = strings.TrimSpace(fields.Title)
	fields.Artist = strings.TrimSpace(fields.Artist)
	fields.Album = strings.TrimSpace(fields.Album)
	fields.Genre = strings.TrimSpace(fields.Genre)
	fields.Description = strings.TrimSpace(fields.Description)
	fields.Lyrics = strings.TrimSpace(fields.Lyrics)
	fields.Language = strings.TrimSpace(fields.Language)
	fields.AuthorName = strings.TrimSpace(fields.AuthorName)
	fields.LicenseURL = strings.TrimSpace(fields.LicenseURL)
	fields.Kind = normalizeKind(fields.Kind)
	fields.Quality = strings.ToLower(strings.TrimSpace(fields.Quality))
	if fields.Quality == "" {
		fields.Quality = "medium"
	}
	if fields.Quality != "low" && fields.Quality != "medium" && fields.Quality != "high" && fields.Quality != "lossless" {
		return fields, fmt.Errorf("invalid quality")
	}
	fields.AuthorMode = normalizeAuthorMode(fields.AuthorMode, false)
	fields.SourceType = normalizeSourceType(fields.SourceType)
	fields.License = normalizeLicense(fields.License)
	fields.Visibility = normalizeVisibility(fields.Visibility)
	if fields.AuthorName == "" {
		fields.AuthorName = fields.Artist
	}
	if fields.Title == "" {
		ext := filepath.Ext(filename)
		fields.Title = strings.TrimSpace(strings.TrimSuffix(filepath.Base(filename), ext))
	}
	genres, err := normalizePublicationList(fields.Genres, 8, 48)
	if err != nil {
		return fields, err
	}
	tags, err := normalizePublicationList(fields.Tags, 30, 48)
	if err != nil {
		return fields, err
	}
	fields.Genres, fields.Tags = genres, tags
	if !validMetadataText(fields.Title, 200) || !validMetadataText(fields.Artist, 120) || !validMetadataText(fields.Album, 120) ||
		!validMetadataText(fields.Genre, 80) || !validMetadataText(fields.Description, 4000) || !validMetadataText(fields.Lyrics, 20000) ||
		!validMetadataText(fields.Language, 32) || !validMetadataText(fields.AuthorName, 160) ||
		!validText(fields.LicenseURL, 512) || !validExternalURL(fields.LicenseURL) {
		return fields, fmt.Errorf("metadata too large or invalid")
	}
	if fields.AuthorMode == "anonymous" {
		if !validAnonAuthorID(fields.AnonAuthorID) {
			fields.AnonAuthorID = "anon_" + randID(16)
		}
	} else {
		fields.AnonAuthorID = ""
	}
	return fields, nil
}

func publicationMetadataPayload(session *PublicationSession, fields PublicationFields) map[string]interface{} {
	return map[string]interface{}{
		"filename":    session.Filename,
		"title":       fields.Title,
		"artist":      fields.Artist,
		"album":       fields.Album,
		"genre":       fields.Genre,
		"description": fields.Description,
		"lyrics":      fields.Lyrics,
		"size":        session.OriginalSize,
	}
}

func mapString(value interface{}) string {
	s, _ := value.(string)
	return strings.TrimSpace(s)
}

func mapFloat(value interface{}) float64 {
	switch n := value.(type) {
	case float64:
		return n
	case float32:
		return float64(n)
	case int:
		return float64(n)
	case json.Number:
		v, _ := n.Float64()
		return v
	default:
		return 0
	}
}

func mapStringList(value interface{}) []string {
	items, ok := value.([]interface{})
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s := mapString(item); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func publicationMatchFromRow(row interface{}, source string) (PublicationMatch, bool) {
	obj, ok := row.(map[string]interface{})
	if !ok {
		return PublicationMatch{}, false
	}
	track, _ := obj["track"].(map[string]interface{})
	if track == nil {
		track = obj
	}
	m := PublicationMatch{
		ID: mapString(track["ID"]), Title: mapString(track["Title"]), Artist: mapString(track["Artist"]),
		Album: mapString(track["Album"]), Slug: mapString(track["Slug"]), Score: mapFloat(obj["score"]),
		Reasons: mapStringList(obj["reasons"]), Source: source,
	}
	if m.ID == "" && m.Title == "" && m.URL == "" {
		return PublicationMatch{}, false
	}
	return m, true
}

func publicationResearchFromRow(row interface{}) (PublicationResearch, bool) {
	obj, ok := row.(map[string]interface{})
	if !ok {
		return PublicationResearch{}, false
	}
	r := PublicationResearch{
		Title: mapString(obj["title"]), URL: mapString(obj["url"]), Snippet: mapString(obj["snippet"]),
	}
	if r.Title == "" {
		r.Title = mapString(obj["name"])
	}
	if r.Title == "" && r.URL == "" && r.Snippet == "" {
		return PublicationResearch{}, false
	}
	if len([]rune(r.Snippet)) > 480 {
		r.Snippet = string([]rune(r.Snippet)[:480]) + "…"
	}
	return r, true
}

func cleanFilenameTitle(filename string) string {
	ext := filepath.Ext(filename)
	stem := strings.TrimSpace(strings.TrimSuffix(filepath.Base(filename), ext))
	stem = strings.ReplaceAll(stem, "_", " ")
	stem = strings.Join(strings.Fields(stem), " ")
	clean := strings.TrimSpace(publicationFilenameNoise.ReplaceAllString(stem, ""))
	if clean == "" {
		return stem
	}
	return clean
}

func publicationAnalysisFromResponses(session *PublicationSession, fields PublicationFields, fill map[string]interface{}, check map[string]interface{}, search map[string]interface{}, ghogemAvailable bool) *PublicationAnalysis {
	analysis := &PublicationAnalysis{
		GeneratedAt: time.Now().UTC(), ProposedFields: map[string]string{}, ProposedReasons: map[string]string{}, GhoGemAvailable: ghogemAvailable,
	}
	if check != nil {
		analysis.ModerationRequired, _ = check["moderation_required"].(bool)
		if rows, ok := check["matches"].([]interface{}); ok {
			for _, row := range rows {
				if match, good := publicationMatchFromRow(row, "catalog"); good {
					analysis.Similar = append(analysis.Similar, match)
				}
			}
		}
	}
	if search != nil {
		if rows, ok := search["matches"].([]interface{}); ok {
			for _, row := range rows {
				match, good := publicationMatchFromRow(row, "catalog")
				if !good {
					continue
				}
				duplicate := false
				for _, old := range analysis.Similar {
					if old.ID != "" && old.ID == match.ID {
						duplicate = true
						break
					}
				}
				if !duplicate {
					analysis.Similar = append(analysis.Similar, match)
				}
			}
		}
		if rows, ok := search["external"].([]interface{}); ok {
			for _, row := range rows {
				if research, good := publicationResearchFromRow(row); good && len(analysis.Research) < 20 {
					analysis.Research = append(analysis.Research, research)
				}
			}
		}
	}
	if len(analysis.Similar) > 0 && !analysis.ModerationRequired {
		// A catalog hit from the broad research pass is still a warning. The
		// dedicated duplicate checker remains authoritative for strong matches.
		for _, match := range analysis.Similar {
			if match.Score >= 6 {
				analysis.ModerationRequired = true
				break
			}
		}
	}
	if len(analysis.Similar) > 0 {
		analysis.Warning = "GhoGem нашёл похожие публикации. Звук не заблокирован, но при продолжении попадёт на модерацию."
		analysis.Summary = fmt.Sprintf("Найдено похожих публикаций: %d. Проверьте совпадения перед отправкой.", len(analysis.Similar))
	} else {
		analysis.Summary = "Сильных совпадений в каталоге не найдено. Проверьте поля и решите, публиковать ли звук сразу."
	}
	if !ghogemAvailable {
		analysis.ModerationRequired = true
		analysis.Warning = "GhoGem временно недоступен. Публикация разрешена только после ручной проверки модератором."
		analysis.Summary = "Автоматическая проверка не завершилась; данные сохранены для ручной проверки."
	}

	// Filename parsing is conservative: it offers changes, never silently
	// overwrites the fields the user just entered.
	if fill != nil {
		for _, key := range []string{"title", "artist", "album", "genre"} {
			candidate := mapString(fill[key])
			if candidate == "" {
				continue
			}
			current := map[string]string{"title": fields.Title, "artist": fields.Artist, "album": fields.Album, "genre": fields.Genre}[key]
			if current == "" {
				analysis.ProposedFields[key] = candidate
				analysis.ProposedReasons[key] = "поле найдено по имени файла"
			}
		}
	}
	cleanTitle := cleanFilenameTitle(session.Filename)
	if cleanTitle != "" && (strings.EqualFold(fields.Title, strings.TrimSpace(strings.TrimSuffix(filepath.Base(session.Filename), filepath.Ext(session.Filename)))) || strings.Contains(strings.ToLower(fields.Title), strings.ToLower(cleanTitle))) && !strings.EqualFold(fields.Title, cleanTitle) {
		analysis.ProposedFields["title"] = cleanTitle
		analysis.ProposedReasons["title"] = "из названия файла убран технический числовой суффикс"
	}
	if len(analysis.ProposedFields) == 0 {
		analysis.ProposedFields = nil
		analysis.ProposedReasons = nil
	}

	var dossier strings.Builder
	fmt.Fprintf(&dossier, "Файл: %s\nРазмер: %s\nТип: %s\n", session.Filename, formatBytes(session.OriginalSize), session.Mime)
	fmt.Fprintf(&dossier, "Поля на момент проверки: «%s» — %s", fields.Title, fields.Artist)
	if fields.Album != "" {
		fmt.Fprintf(&dossier, ", альбом «%s»", fields.Album)
	}
	dossier.WriteString(".\n\n")
	dossier.WriteString(analysis.Summary + "\n")
	if len(analysis.Similar) > 0 {
		dossier.WriteString("Похожие публикации:\n")
		for _, match := range analysis.Similar[:minInt(len(analysis.Similar), 8)] {
			name := strings.TrimSpace(strings.TrimSpace(match.Title) + " — " + strings.TrimSpace(match.Artist))
			if name == "—" || name == "" {
				name = match.ID
			}
			fmt.Fprintf(&dossier, "- %s", name)
			if match.Score > 0 {
				fmt.Fprintf(&dossier, " (оценка %.0f)", match.Score)
			}
			dossier.WriteString("\n")
		}
	}
	if len(analysis.Research) > 0 {
		fmt.Fprintf(&dossier, "\nВеб-ресерч: найдено внешних результатов %d; ссылки доступны в карточке анализа.\n", len(analysis.Research))
	} else {
		dossier.WriteString("\nВеб-ресерч: подтверждённых внешних результатов нет.\n")
	}
	if len(analysis.ProposedFields) > 0 {
		dossier.WriteString("\nGhoGem предлагает изменения полей; каждое изменение нужно подтвердить отдельно.\n")
	}
	if analysis.ModerationRequired {
		dossier.WriteString("Решение: продолжение публикации разрешено, но звук будет отправлен на модерацию.\n")
	} else {
		dossier.WriteString("Решение: сильных причин для обязательной модерации не найдено; можно опубликовать после проверки формы.\n")
	}
	analysis.Dossier = dossier.String()
	return analysis
}

func formatBytes(value int64) string {
	if value <= 0 {
		return "неизвестно"
	}
	units := []string{"Б", "КБ", "МБ", "ГБ"}
	n := float64(value)
	idx := 0
	for n >= 1024 && idx < len(units)-1 {
		n /= 1024
		idx++
	}
	if idx == 0 {
		return fmt.Sprintf("%d %s", value, units[idx])
	}
	return fmt.Sprintf("%.1f %s", n, units[idx])
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func publicationStageAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		publicationJSONError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if !publicMutationOriginOK(r) {
		publicationJSONError(w, http.StatusForbidden, "origin rejected")
		return
	}
	if !requirePublicationAccount(w, r) {
		return
	}
	cleanupPublicationSessions()
	rateID := rateKey(r)
	if !reserveUpload(rateID) {
		publicationJSONError(w, http.StatusTooManyRequests, "limit reached")
		return
	}
	reserved := true
	defer func() {
		if reserved {
			releaseUpload(rateID)
		}
	}()

	r.Body = http.MaxBytesReader(w, r.Body, MAX_SIZE+2<<20)
	if err := r.ParseMultipartForm(2 << 20); err != nil {
		publicationJSONError(w, http.StatusBadRequest, "file too large")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		publicationJSONError(w, http.StatusBadRequest, "no file")
		return
	}
	defer file.Close()
	filename := filepath.Base(strings.ReplaceAll(header.Filename, "\\", "/"))
	if filename == "." || filename == "" || len(filename) > 255 || !validText(filename, 255) || !publicationStageAllowed(filename, header.Header.Get("Content-Type")) {
		publicationJSONError(w, http.StatusBadRequest, "invalid audio file")
		return
	}
	id := randID(24)
	path := publicationSessionPath(id)
	if path == "" {
		publicationJSONError(w, http.StatusInternalServerError, "could not create upload session")
		return
	}
	dst, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0600)
	if err != nil {
		publicationJSONError(w, http.StatusServiceUnavailable, "storage unavailable")
		return
	}
	written, copyErr := io.Copy(dst, io.LimitReader(file, MAX_SIZE+1))
	closeErr := dst.Close()
	if copyErr != nil || closeErr != nil || written <= 0 || written > MAX_SIZE {
		_ = os.Remove(path)
		publicationJSONError(w, http.StatusBadRequest, "upload failed")
		return
	}
	if _, probeErr := probeAudioInput(path); probeErr != nil {
		_ = os.Remove(path)
		publicationJSONError(w, http.StatusUnsupportedMediaType, "only a real audio file is accepted")
		return
	}
	owner := publicationOwnerID(r)
	mime := strings.TrimSpace(header.Header.Get("Content-Type"))
	if mime == "" {
		mime = "audio/*"
	}
	now := time.Now()
	session := &PublicationSession{ID: id, OwnerID: owner, RateKey: rateID, FilePath: path, Filename: filename, Mime: mime, OriginalSize: written, Stage: "file_uploaded", CreatedAt: now, UpdatedAt: now}
	workflowStore.mu.Lock()
	workflowStore.publications[id] = session
	workflowStore.mu.Unlock()
	reserved = false
	save()
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"status": "staged", "stage": session.Stage, "session_id": id, "filename": filename, "mime": mime, "original_size": written})
}

func publicationAnalyzeAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		publicationJSONError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if !publicMutationOriginOK(r) {
		publicationJSONError(w, http.StatusForbidden, "origin rejected")
		return
	}
	if !requirePublicationAccount(w, r) {
		return
	}
	if !allowAI(r) {
		publicationJSONError(w, http.StatusTooManyRequests, "rate limit")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, AI_BODY_MAX)
	var req publicationAnalyzeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		publicationJSONError(w, http.StatusBadRequest, "bad json")
		return
	}
	session, err := publicationSessionForRequest(r, strings.TrimSpace(req.SessionID))
	if err != nil || (session.Stage != "file_uploaded" && session.Stage != "analyzed") {
		publicationJSONError(w, http.StatusConflict, "publication file is not ready for analysis")
		return
	}
	if path := publicationSessionPath(session.ID); path == "" {
		publicationJSONError(w, http.StatusConflict, "publication file is missing")
		return
	} else if info, statErr := os.Stat(path); statErr != nil || info.Size() <= 0 {
		publicationJSONError(w, http.StatusConflict, "publication file is missing")
		return
	}
	fields, err := normalizePublicationFields(req.Fields, session.Filename)
	if err != nil {
		publicationJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	payload := publicationMetadataPayload(session, fields)
	fillRaw, fillErr := ghogemCall("/api/ghosou/metadata/fill", payload)
	var fill map[string]interface{}
	if fillErr == nil {
		_ = json.Unmarshal(fillRaw, &fill)
	}
	checkCh := make(chan map[string]interface{}, 1)
	searchCh := make(chan map[string]interface{}, 1)
	go func() {
		raw, callErr := ghogemCall("/api/ghosou/metadata/check", payload)
		out := map[string]interface{}{}
		if callErr == nil {
			_ = json.Unmarshal(raw, &out)
		}
		checkCh <- out
	}()
	query := strings.TrimSpace(strings.Join([]string{fields.Title, fields.Artist, fields.Album, session.Filename}, " "))
	go func() {
		raw, callErr := ghogemCall("/api/ghosou/search", map[string]interface{}{
			"query": query, "filename": session.Filename, "title": fields.Title, "artist": fields.Artist,
			"album": fields.Album, "genre": fields.Genre, "description": fields.Description,
			"lyrics": fields.Lyrics, "size": session.OriginalSize, "limit": 20, "scope": "catalog",
		})
		out := map[string]interface{}{}
		if callErr == nil {
			_ = json.Unmarshal(raw, &out)
		}
		searchCh <- out
	}()
	check := <-checkCh
	search := <-searchCh
	ghogemAvailable := fillErr == nil || len(check) > 0 || len(search) > 0
	if fillErr != nil && len(check) == 0 && len(search) == 0 {
		ghogemAvailable = false
	}
	analysis := publicationAnalysisFromResponses(session, fields, fill, check, search, ghogemAvailable)
	workflowStore.mu.Lock()
	current := workflowStore.publications[session.ID]
	if current == nil || current.OwnerID != publicationOwnerID(r) || current.Stage == "finalizing" || current.Stage == "finalized" {
		workflowStore.mu.Unlock()
		publicationJSONError(w, http.StatusConflict, "publication session changed")
		return
	}
	current.Fields = clonePublicationFields(fields)
	current.Analysis = clonePublicationAnalysis(analysis)
	current.Stage = "analyzed"
	current.UpdatedAt = time.Now()
	result := clonePublicationSession(current)
	workflowStore.mu.Unlock()
	save()
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"status": "ok", "stage": result.Stage, "session_id": result.ID, "fields": result.Fields, "analysis": result.Analysis})
}

func publicationFinalizeAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		publicationJSONError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if !publicMutationOriginOK(r) {
		publicationJSONError(w, http.StatusForbidden, "origin rejected")
		return
	}
	if !requirePublicationAccount(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, COVER_MAX+256<<10)
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		publicationJSONError(w, http.StatusBadRequest, "invalid finalization request")
		return
	}
	id := strings.TrimSpace(r.FormValue("session_id"))
	session, err := publicationSessionForRequest(r, id)
	if err != nil || session.Stage != "analyzed" || session.Analysis == nil {
		publicationJSONError(w, http.StatusConflict, "analysis confirmation is required")
		return
	}
	confirmed := strings.EqualFold(strings.TrimSpace(r.FormValue("confirmed")), "true")
	decision := strings.ToLower(strings.TrimSpace(r.FormValue("decision")))
	if decision != "publish" && decision != "moderate" {
		if session.Analysis.ModerationRequired {
			decision = "moderate"
		} else {
			decision = "publish"
		}
	}
	if session.Analysis.ModerationRequired && (!confirmed || decision != "moderate") {
		publicationJSONError(w, http.StatusConflict, "similar publication confirmation is required")
		return
	}
	fields := session.Fields
	if rawFields := strings.TrimSpace(r.FormValue("fields")); rawFields != "" {
		if err := json.Unmarshal([]byte(rawFields), &fields); err != nil {
			publicationJSONError(w, http.StatusBadRequest, "invalid publication fields")
			return
		}
	}
	fields, err = normalizePublicationFields(fields, session.Filename)
	if err != nil {
		publicationJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	if fields.AuthorMode == "account" && resolvedAccountID(r) == "" {
		publicationJSONError(w, http.StatusUnauthorized, "account required for creator mode")
		return
	}
	workflowStore.mu.Lock()
	current := workflowStore.publications[session.ID]
	if current == nil || current.OwnerID != publicationOwnerID(r) || current.Stage != "analyzed" {
		workflowStore.mu.Unlock()
		publicationJSONError(w, http.StatusConflict, "publication session is already being finalized")
		return
	}
	current.Stage = "finalizing"
	current.Fields = clonePublicationFields(fields)
	current.Decision = decision
	current.UpdatedAt = time.Now()
	session = clonePublicationSession(current)
	workflowStore.mu.Unlock()
	save()

	completed := false
	coverPath := ""
	defer func() {
		if !completed {
			workflowStore.mu.Lock()
			if current := workflowStore.publications[session.ID]; current != nil && current.Stage == "finalizing" {
				current.Stage = "analyzed"
				current.UpdatedAt = time.Now()
			}
			workflowStore.mu.Unlock()
			if coverPath != "" {
				_ = os.Remove(coverPath)
			}
			save()
		}
	}()

	bitrateMap := map[string]string{"low": "64k", "medium": "96k", "high": "192k", "lossless": "256k"}
	br := bitrateMap[fields.Quality]
	if br == "" {
		br = "96k"
	}
	if _, probeErr := probeAudioInput(session.FilePath); probeErr != nil {
		publicationJSONError(w, http.StatusUnsupportedMediaType, "only a real audio file is accepted")
		return
	}
	idTrack := randID(12)
	ogg := filepath.Join("./uploads", randID(12)+".ogg")
	if err := runMediaCommand(2*time.Minute, "ffmpeg", "-nostdin", "-v", "error", "-i", session.FilePath, "-map", "0:a:0", "-map_metadata", "-1", "-vn", "-sn", "-dn", "-c:a", "libopus", "-b:a", br, "-application", "audio", ogg); err != nil {
		_ = os.Remove(ogg)
		publicationJSONError(w, http.StatusUnprocessableEntity, "audio processing failed")
		return
	}
	info, statErr := os.Stat(ogg)
	if statErr != nil || info.Size() <= 0 {
		_ = os.Remove(ogg)
		publicationJSONError(w, http.StatusUnprocessableEntity, "audio processing failed")
		return
	}
	duration := 0.0
	if value, probeErr := probeDuration(ogg); probeErr == nil {
		duration = value
	}
	if r.MultipartForm != nil && len(r.MultipartForm.File["cover"]) > 0 {
		coverFile, coverHeader, coverErr := r.FormFile("cover")
		if coverErr != nil {
			_ = os.Remove(ogg)
			publicationJSONError(w, http.StatusBadRequest, "invalid cover")
			return
		}
		coverPath, coverErr = processCoverUpload(coverFile, coverHeader.Filename, idTrack)
		coverFile.Close()
		if coverErr != nil {
			_ = os.Remove(ogg)
			if strings.Contains(coverErr.Error(), "processing") {
				publicationJSONError(w, http.StatusUnprocessableEntity, "cover processing failed")
			} else {
				publicationJSONError(w, http.StatusBadRequest, "cover upload failed")
			}
			return
		}
	}

	moderationStatus := "published"
	trackStatus := "published"
	if decision == "moderate" || session.Analysis.ModerationRequired {
		moderationStatus, trackStatus = "pending", "pending"
	}
	authorMode := fields.AuthorMode
	anonAuthorID := fields.AnonAuthorID
	actorType, actorID, _ := actorForRequest(r, anonAuthorID)
	if authorMode == "anonymous" {
		actorType, actorID = "anonymous", anonAuthorID
	}
	trackUserID := userID(r)
	if authorMode == "anonymous" {
		trackUserID = ""
	}
	now := time.Now()
	newTrack := &Track{
		ID: idTrack, Filename: session.Filename, Title: fields.Title, Artist: fields.Artist, Album: fields.Album, Genre: fields.Genre,
		Description: fields.Description, Lyrics: fields.Lyrics, Duration: duration, File: ogg, Mime: "audio/ogg", Cover: coverPath,
		Size: float64(info.Size()), OriginalSize: session.OriginalSize, UserID: trackUserID, Slug: slug(fields.Title) + "-" + randID(4),
		IsAnonymous: authorMode == "anonymous", AIEdit: len(session.Analysis.ProposedFields) > 0, Bitrate: br, Status: trackStatus, CreatedAt: now, UpdatedAt: now,
		Kind: fields.Kind, AuthorMode: authorMode, AuthorName: fields.AuthorName, AnonAuthorID: anonAuthorID, Genres: cloneStrings(fields.Genres), Tags: cloneStrings(fields.Tags),
		Language: fields.Language, SourceType: fields.SourceType, License: fields.License, LicenseURL: fields.LicenseURL, Visibility: fields.Visibility,
		DownloadAllowed: fields.DownloadAllowed, ModerationStatus: moderationStatus, Revision: 1, CurrentRevisionID: revisionIDFor(idTrack, 1),
		PublicationAnalysis: clonePublicationAnalysis(session.Analysis),
	}
	if moderationStatus == "published" {
		newTrack.PublishedAt = now
	}
	appendRevision(newTrack, actorType, actorID, "initial publication", moderationStatus)
	store.mu.Lock()
	store.m[newTrack.ID] = newTrack
	store.mu.Unlock()
	_ = os.Remove(session.FilePath)
	workflowStore.mu.Lock()
	if current := workflowStore.publications[session.ID]; current != nil {
		current.Stage = "finalized"
		current.PublishedTrackID = newTrack.ID
		current.Decision = decision
		current.FilePath = ""
		current.UpdatedAt = time.Now()
	}
	workflowStore.mu.Unlock()
	completed = true
	save()
	if moderationStatus == "pending" {
		notifyGhoGemTrackModeration(newTrack)
	}
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"status": "ok", "id": newTrack.ID, "slug": newTrack.Slug, "kind": newTrack.Kind, "moderation_status": moderationStatus, "decision": decision, "dossier": session.Analysis.Dossier})
}

func publicationStageItemAPI(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/sound/api/upload/stage/")
	preview := false
	if strings.HasSuffix(path, "/preview") {
		preview = true
		path = strings.TrimSuffix(path, "/preview")
	}
	if !publicationSessionIDValid(path) {
		publicationJSONError(w, http.StatusBadRequest, "bad publication session")
		return
	}
	session, err := publicationSessionForRequest(r, path)
	if err != nil {
		publicationJSONError(w, http.StatusNotFound, "publication session not found")
		return
	}
	if preview && r.Method == http.MethodGet {
		if session.Stage == "finalized" || session.FilePath == "" {
			publicationJSONError(w, http.StatusNotFound, "publication file not found")
			return
		}
		file, openErr := os.Open(session.FilePath)
		if openErr != nil {
			publicationJSONError(w, http.StatusNotFound, "publication file not found")
			return
		}
		defer file.Close()
		w.Header().Set("Content-Type", session.Mime)
		w.Header().Set("Cache-Control", "private, no-store")
		http.ServeContent(w, r, session.Filename, session.UpdatedAt, file)
		return
	}
	if r.Method != http.MethodDelete && r.Method != http.MethodPost {
		publicationJSONError(w, http.StatusMethodNotAllowed, "DELETE or POST only")
		return
	}
	if !publicMutationOriginOK(r) {
		publicationJSONError(w, http.StatusForbidden, "origin rejected")
		return
	}
	if session.Stage == "finalized" {
		publicationJSONError(w, http.StatusConflict, "publication already finalized")
		return
	}
	workflowStore.mu.Lock()
	delete(workflowStore.publications, path)
	workflowStore.mu.Unlock()
	if session.FilePath != "" {
		_ = os.Remove(session.FilePath)
	}
	releaseUpload(session.RateKey)
	save()
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "cancelled", "session_id": path})
}

func cleanupPublicationSessions() {
	now := time.Now()
	var expired []*PublicationSession
	workflowStore.mu.Lock()
	for id, session := range workflowStore.publications {
		if session == nil || session.Stage == "finalized" {
			if session != nil && !session.UpdatedAt.IsZero() && now.Sub(session.UpdatedAt) < publicationSessionTTL {
				continue
			}
		} else if now.Sub(session.UpdatedAt) < publicationSessionTTL {
			continue
		}
		if session != nil {
			expired = append(expired, clonePublicationSession(session))
		}
		delete(workflowStore.publications, id)
	}
	workflowStore.mu.Unlock()
	if len(expired) == 0 {
		return
	}
	for _, session := range expired {
		if session.FilePath != "" {
			_ = os.Remove(session.FilePath)
		}
		releaseUpload(session.RateKey)
	}
	save()
}

func publicationSessionJanitor() {
	ticker := time.NewTicker(15 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		cleanupPublicationSessions()
	}
}

// Keep the admin response useful even when the public Track shape must stay
// deliberately small and must not expose the internal dossier.
func sortAdminSounds(items []*adminSoundView) {
	sort.Slice(items, func(i, j int) bool {
		if items[i] == nil || items[i].PublicTrack == nil {
			return false
		}
		if items[j] == nil || items[j].PublicTrack == nil {
			return true
		}
		return items[i].CreatedAt.Before(items[j].CreatedAt)
	})
}
