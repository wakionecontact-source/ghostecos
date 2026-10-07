package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// TrackRevision is an immutable snapshot of a published or proposed sound.
// Track.UserID remains only as a legacy/internal migration field; it is never
// used as public ownership after the revision workflow is enabled.
type TrackRevision struct {
	ID            string    `json:"id"`
	SoundID       string    `json:"sound_id"`
	Number        int       `json:"number"`
	Snapshot      Track     `json:"snapshot"`
	ActorType     string    `json:"actor_type"`
	ActorPublicID string    `json:"actor_public_id"`
	Summary       string    `json:"summary"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"created_at"`
	ApprovedAt    time.Time `json:"approved_at"`
}

type PublicRevision struct {
	ID            string       `json:"id"`
	SoundID       string       `json:"sound_id"`
	Number        int          `json:"number"`
	Snapshot      *PublicTrack `json:"snapshot"`
	ActorType     string       `json:"actor_type"`
	ActorPublicID string       `json:"actor_public_id,omitempty"`
	Summary       string       `json:"summary"`
	CreatedAt     time.Time    `json:"created_at"`
	ApprovedAt    time.Time    `json:"approved_at,omitempty"`
}

func publicRevision(revision *TrackRevision) *PublicRevision {
	if revision == nil {
		return nil
	}
	actorID := revision.ActorPublicID
	if revision.ActorType != "anonymous" {
		actorID = ""
	}
	return &PublicRevision{
		ID: revision.ID, SoundID: revision.SoundID, Number: revision.Number,
		Snapshot: publicTrack(&revision.Snapshot), ActorType: revision.ActorType,
		ActorPublicID: actorID, Summary: revision.Summary, CreatedAt: revision.CreatedAt,
		ApprovedAt: revision.ApprovedAt,
	}
}

// TrackPatch contains only user-editable public metadata. Binary replacement,
// licensing and takedown actions will use dedicated moderated workflows.
type TrackPatch struct {
	Title           *string   `json:"title"`
	Artist          *string   `json:"artist"`
	Album           *string   `json:"album"`
	Genre           *string   `json:"genre"`
	Description     *string   `json:"description"`
	Lyrics          *string   `json:"lyrics"`
	Kind            *string   `json:"kind"`
	AuthorMode      *string   `json:"author_mode"`
	AuthorName      *string   `json:"author_name"`
	AnonAuthorID    *string   `json:"anon_author_id"`
	Genres          *[]string `json:"genres"`
	Tags            *[]string `json:"tags"`
	Language        *string   `json:"language"`
	SourceType      *string   `json:"source_type"`
	License         *string   `json:"license"`
	LicenseURL      *string   `json:"license_url"`
	Visibility      *string   `json:"visibility"`
	DownloadAllowed *bool     `json:"download_allowed"`
}

type ChangeSet struct {
	ID            string     `json:"id"`
	SoundID       string     `json:"sound_id"`
	BaseRevision  string     `json:"base_revision"`
	Patch         TrackPatch `json:"patch"`
	Summary       string     `json:"summary"`
	ActorType     string     `json:"actor_type"`
	ActorPublicID string     `json:"actor_public_id"`
	Status        string     `json:"status"`
	Reason        string     `json:"reason"`
	CreatedAt     time.Time  `json:"created_at"`
	ReviewedAt    time.Time  `json:"reviewed_at"`
	ReviewedBy    string     `json:"reviewed_by"`
	ReviewNote    string     `json:"review_note"`
}

type VerificationApplication struct {
	ID          string    `json:"id"`
	AccountID   string    `json:"account_id"`
	ArtistName  string    `json:"artist_name"`
	Website     string    `json:"website"`
	SocialLinks []string  `json:"social_links"`
	SoundIDs    []string  `json:"sound_ids"`
	Evidence    string    `json:"evidence"`
	Statement   string    `json:"statement"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
	ReviewedAt  time.Time `json:"reviewed_at"`
	ReviewedBy  string    `json:"reviewed_by"`
	ReviewNote  string    `json:"review_note"`
}

var workflowStore = struct {
	mu            sync.RWMutex
	revisions     map[string][]*TrackRevision
	changesets    map[string]*ChangeSet
	verifications map[string]*VerificationApplication
	publications  map[string]*PublicationSession
}{
	revisions:     make(map[string][]*TrackRevision),
	changesets:    make(map[string]*ChangeSet),
	verifications: make(map[string]*VerificationApplication),
	publications:  make(map[string]*PublicationSession),
}

func cloneStrings(values []string) []string {
	if values == nil {
		return nil
	}
	return append([]string(nil), values...)
}

func cloneTrack(t *Track) *Track {
	if t == nil {
		return nil
	}
	c := *t
	c.Genres = cloneStrings(t.Genres)
	c.Tags = cloneStrings(t.Tags)
	return &c
}

func validKind(value string) bool {
	switch value {
	case "music", "sound", "voice", "podcast", "ambient", "loop", "sample", "audiobook", "other":
		return true
	default:
		return false
	}
}

func normalizeKind(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if validKind(value) {
		return value
	}
	return "music"
}

func validAuthorMode(value string) bool {
	switch value {
	case "named", "account", "anonymous", "collective", "unknown":
		return true
	default:
		return false
	}
}

func normalizeAuthorMode(value string, anonymous bool) string {
	if anonymous {
		return "anonymous"
	}
	value = strings.ToLower(strings.TrimSpace(value))
	if validAuthorMode(value) {
		return value
	}
	return "named"
}

func validVisibility(value string) bool {
	switch value {
	case "public", "unlisted", "private":
		return true
	default:
		return false
	}
}

func normalizeVisibility(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if validVisibility(value) {
		return value
	}
	return "public"
}

func validLicense(value string) bool {
	switch value {
	case "all_rights_reserved", "cc0", "cc_by", "cc_by_sa", "cc_by_nc", "custom", "unknown":
		return true
	default:
		return false
	}
}

func normalizeLicense(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if validLicense(value) {
		return value
	}
	return "all_rights_reserved"
}

func validSourceType(value string) bool {
	switch value {
	case "original", "cover", "remix", "mashup", "sample_based", "archive", "public_domain", "unknown":
		return true
	default:
		return false
	}
}

func normalizeSourceType(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if validSourceType(value) {
		return value
	}
	return "unknown"
}

func trackPubliclyReadable(t *Track) bool {
	if t == nil || t.ModerationStatus != "published" {
		return false
	}
	return t.Visibility == "public" || t.Visibility == "unlisted"
}

func localCatalogSearch(query, kind string, limit int) []*PublicTrack {
	query = strings.ToLower(strings.TrimSpace(query))
	if len(query) > 240 {
		query = query[:240]
	}
	terms := strings.Fields(query)
	if len(terms) > 8 {
		terms = terms[:8]
	}
	kind = strings.ToLower(strings.TrimSpace(kind))
	type result struct {
		track *PublicTrack
		score int
	}
	hits := make([]result, 0)
	store.mu.RLock()
	for _, t := range store.m {
		if t == nil || t.ModerationStatus != "published" || t.Visibility != "public" || (kind != "" && t.Kind != kind) {
			continue
		}
		fields := strings.ToLower(strings.Join([]string{t.ID, t.Filename, t.Slug, t.Title, t.Artist, t.Album, t.Genre, t.Description, strings.Join(t.Tags, " "), strings.Join(t.Genres, " ")}, " "))
		score := 0
		for _, term := range terms {
			if strings.Contains(fields, term) {
				score++
			}
		}
		if score == len(terms) {
			hits = append(hits, result{track: catalogTrack(t), score: score})
		}
	}
	store.mu.RUnlock()
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].score != hits[j].score {
			return hits[i].score > hits[j].score
		}
		return hits[i].track.Plays > hits[j].track.Plays
	})
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	if len(hits) > limit {
		hits = hits[:limit]
	}
	out := make([]*PublicTrack, 0, len(hits))
	for _, hit := range hits {
		out = append(out, hit.track)
	}
	return out
}

func validAnonAuthorID(value string) bool {
	if len(value) != 37 || !strings.HasPrefix(value, "anon_") {
		return false
	}
	return isLowerHex(value[5:])
}

func parseList(value string, maxItems, maxItemBytes int) ([]string, bool) {
	parts := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r' || r == ';'
	})
	result := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if len(part) > maxItemBytes || !validMetadataText(part, maxItemBytes) {
			return nil, false
		}
		part = strings.ToLower(part)
		if _, ok := seen[part]; ok {
			continue
		}
		seen[part] = struct{}{}
		result = append(result, part)
		if len(result) > maxItems {
			return nil, false
		}
	}
	return result, true
}

func validExternalURL(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return true
	}
	if strings.ContainsAny(value, "\r\n") {
		return false
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" {
		return false
	}
	return strings.EqualFold(parsed.Scheme, "http") || strings.EqualFold(parsed.Scheme, "https")
}

func actorForRequest(r *http.Request, anonID string) (string, string, bool) {
	if validAnonAuthorID(anonID) {
		return "anonymous", anonID, true
	}
	if accountID := resolvedAccountID(r); accountID != "" {
		return "account", accountID, true
	}
	return "anonymous", "", true
}

func revisionIDFor(soundID string, number int) string {
	return fmt.Sprintf("%s-r%d-%s", soundID, number, randID(4))
}

func appendRevisionLocked(t *Track, actorType, actorPublicID, summary, status string) {
	if t == nil {
		return
	}
	if t.Revision <= 0 {
		t.Revision = 1
	}
	if t.CurrentRevisionID == "" {
		t.CurrentRevisionID = revisionIDFor(t.ID, t.Revision)
	}
	revision := &TrackRevision{
		ID:            t.CurrentRevisionID,
		SoundID:       t.ID,
		Number:        t.Revision,
		Snapshot:      *cloneTrack(t),
		ActorType:     actorType,
		ActorPublicID: actorPublicID,
		Summary:       summary,
		Status:        status,
		CreatedAt:     time.Now(),
	}
	workflowStore.revisions[t.ID] = append(workflowStore.revisions[t.ID], revision)
}

func appendRevision(t *Track, actorType, actorPublicID, summary, status string) {
	if t == nil {
		return
	}
	workflowStore.mu.Lock()
	appendRevisionLocked(t, actorType, actorPublicID, summary, status)
	workflowStore.mu.Unlock()
}

func normalizeLoadedTrack(t *Track) bool {
	if t == nil {
		return false
	}
	changed := false
	legacy := t.Revision <= 0
	if normalizedKind := normalizeKind(t.Kind); t.Kind != normalizedKind {
		t.Kind = normalizedKind
		changed = true
	}
	normalizedMode := strings.ToLower(strings.TrimSpace(t.AuthorMode))
	if !validAuthorMode(normalizedMode) {
		if t.IsAnonymous {
			normalizedMode = "anonymous"
		} else {
			normalizedMode = "named"
		}
	}
	if t.AuthorMode != normalizedMode {
		t.AuthorMode = normalizedMode
		changed = true
	}
	if t.AuthorName == "" && t.Artist != "" && t.AuthorMode != "anonymous" {
		t.AuthorName = t.Artist
		changed = true
	}
	if t.AuthorMode == "anonymous" {
		if t.UserID != "" {
			t.UserID = ""
			changed = true
		}
		if !validAnonAuthorID(t.AnonAuthorID) {
			t.AnonAuthorID = "anon_" + randID(16)
			changed = true
		}
		t.IsAnonymous = true
	} else if t.AnonAuthorID != "" || t.IsAnonymous {
		t.AnonAuthorID = ""
		t.IsAnonymous = false
		changed = true
	}
	if normalizedVisibility := normalizeVisibility(t.Visibility); t.Visibility != normalizedVisibility {
		t.Visibility = normalizedVisibility
		changed = true
	}
	if t.ModerationStatus == "" {
		t.ModerationStatus = "published"
		changed = true
	}
	if t.Revision <= 0 {
		t.Revision = 1
		changed = true
	}
	if t.CurrentRevisionID == "" {
		t.CurrentRevisionID = revisionIDFor(t.ID, t.Revision)
		changed = true
	}
	if normalizedLicense := normalizeLicense(t.License); t.License != normalizedLicense {
		t.License = normalizedLicense
		changed = true
	}
	if normalizedSource := normalizeSourceType(t.SourceType); t.SourceType != normalizedSource {
		t.SourceType = normalizedSource
		changed = true
	}
	if legacy && !t.DownloadAllowed {
		t.DownloadAllowed = true
		changed = true
	}
	if t.UpdatedAt.IsZero() {
		t.UpdatedAt = t.CreatedAt
		changed = true
	}
	if t.PublishedAt.IsZero() && t.ModerationStatus == "published" {
		t.PublishedAt = t.CreatedAt
		changed = true
	}
	return changed
}

func validateTrackPatch(p TrackPatch) error {
	if p.Title != nil && !validText(*p.Title, 200) {
		return fmt.Errorf("invalid title")
	}
	if p.Artist != nil && !validText(*p.Artist, 120) {
		return fmt.Errorf("invalid artist")
	}
	if p.Album != nil && !validText(*p.Album, 120) {
		return fmt.Errorf("invalid album")
	}
	if p.Genre != nil && !validText(*p.Genre, 80) {
		return fmt.Errorf("invalid genre")
	}
	if p.Description != nil && !validText(*p.Description, 4000) {
		return fmt.Errorf("invalid description")
	}
	if p.Lyrics != nil && !validText(*p.Lyrics, 20000) {
		return fmt.Errorf("invalid lyrics")
	}
	if p.Kind != nil && !validKind(strings.ToLower(strings.TrimSpace(*p.Kind))) {
		return fmt.Errorf("invalid kind")
	}
	if p.AuthorMode != nil && !validAuthorMode(strings.ToLower(strings.TrimSpace(*p.AuthorMode))) {
		return fmt.Errorf("invalid author mode")
	}
	if p.AuthorName != nil && !validText(*p.AuthorName, 160) {
		return fmt.Errorf("invalid author")
	}
	if p.AnonAuthorID != nil && *p.AnonAuthorID != "" && !validAnonAuthorID(*p.AnonAuthorID) {
		return fmt.Errorf("invalid anon id")
	}
	if p.Genres != nil && (len(*p.Genres) > 8) {
		return fmt.Errorf("too many genres")
	}
	if p.Tags != nil && (len(*p.Tags) > 30) {
		return fmt.Errorf("too many tags")
	}
	if p.Language != nil && !validText(*p.Language, 32) {
		return fmt.Errorf("invalid language")
	}
	if p.SourceType != nil && !validSourceType(strings.ToLower(strings.TrimSpace(*p.SourceType))) {
		return fmt.Errorf("invalid source type")
	}
	if p.License != nil && !validLicense(strings.ToLower(strings.TrimSpace(*p.License))) {
		return fmt.Errorf("invalid license")
	}
	if p.LicenseURL != nil && (len(*p.LicenseURL) > 512 || !validText(*p.LicenseURL, 512) || !validExternalURL(*p.LicenseURL)) {
		return fmt.Errorf("invalid license url")
	}
	if p.Visibility != nil && !validVisibility(strings.ToLower(strings.TrimSpace(*p.Visibility))) {
		return fmt.Errorf("invalid visibility")
	}
	if p.Genres != nil {
		for _, item := range *p.Genres {
			if len(item) > 48 || !validText(item, 48) {
				return fmt.Errorf("invalid genre item")
			}
		}
	}
	if p.Tags != nil {
		for _, item := range *p.Tags {
			if len(item) > 48 || !validText(item, 48) {
				return fmt.Errorf("invalid tag item")
			}
		}
	}
	return nil
}

func applyTrackPatch(t *Track, p TrackPatch) {
	if p.Title != nil {
		t.Title = *p.Title
	}
	if p.Artist != nil {
		t.Artist = *p.Artist
	}
	if p.Album != nil {
		t.Album = *p.Album
	}
	if p.Genre != nil {
		t.Genre = *p.Genre
	}
	if p.Description != nil {
		t.Description = *p.Description
	}
	if p.Lyrics != nil {
		t.Lyrics = *p.Lyrics
	}
	if p.Kind != nil {
		t.Kind = normalizeKind(*p.Kind)
	}
	if p.AuthorMode != nil {
		t.AuthorMode = normalizeAuthorMode(*p.AuthorMode, false)
		t.IsAnonymous = t.AuthorMode == "anonymous"
		if t.IsAnonymous && !validAnonAuthorID(t.AnonAuthorID) {
			t.AnonAuthorID = "anon_" + randID(16)
		}
		if !t.IsAnonymous {
			t.AnonAuthorID = ""
		}
	}
	if p.AuthorName != nil {
		t.AuthorName = *p.AuthorName
	}
	if p.AnonAuthorID != nil {
		t.AnonAuthorID = *p.AnonAuthorID
	}
	if p.Genres != nil {
		t.Genres = cloneStrings(*p.Genres)
	}
	if p.Tags != nil {
		t.Tags = cloneStrings(*p.Tags)
	}
	if p.Language != nil {
		t.Language = *p.Language
	}
	if p.SourceType != nil {
		t.SourceType = normalizeSourceType(*p.SourceType)
	}
	if p.License != nil {
		t.License = normalizeLicense(*p.License)
	}
	if p.LicenseURL != nil {
		t.LicenseURL = *p.LicenseURL
	}
	if p.Visibility != nil {
		t.Visibility = normalizeVisibility(*p.Visibility)
	}
	if p.DownloadAllowed != nil {
		t.DownloadAllowed = *p.DownloadAllowed
	}
	if t.AuthorMode == "anonymous" {
		t.IsAnonymous = true
		if !validAnonAuthorID(t.AnonAuthorID) {
			t.AnonAuthorID = "anon_" + randID(16)
		}
	} else {
		t.IsAnonymous = false
		t.AnonAuthorID = ""
	}
	t.UpdatedAt = time.Now()
}

func changesetAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	setCORS(w, r)
	id := strings.TrimPrefix(r.URL.Path, "/sound/api/changesets/")
	if !validTrackID(id) {
		http.Error(w, `{"error":"bad sound id"}`, http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !publicMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	if !allowWorkflowAction(r, 20, time.Hour) {
		http.Error(w, `{"error":"changeset rate limit"}`, http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	var req struct {
		Patch        TrackPatch `json:"patch"`
		Summary      string     `json:"summary"`
		Reason       string     `json:"reason"`
		AnonAuthorID string     `json:"anon_author_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
		return
	}
	if len(req.Summary) > 500 || !validText(req.Summary, 500) || len(req.Reason) > 1000 || !validText(req.Reason, 1000) {
		http.Error(w, `{"error":"invalid change description"}`, http.StatusBadRequest)
		return
	}
	if err := validateTrackPatch(req.Patch); err != nil {
		http.Error(w, `{"error":"invalid patch"}`, http.StatusBadRequest)
		return
	}
	store.mu.RLock()
	t, ok := store.m[id]
	if ok && t != nil {
		t = cloneTrack(t)
	}
	store.mu.RUnlock()
	if !ok || t == nil || t.ModerationStatus != "published" {
		http.Error(w, `{"error":"sound not found"}`, http.StatusNotFound)
		return
	}
	actorType, actorID, _ := actorForRequest(r, req.AnonAuthorID)
	cs := &ChangeSet{
		ID: randID(16), SoundID: id, BaseRevision: t.CurrentRevisionID,
		Patch: req.Patch, Summary: req.Summary, Reason: req.Reason,
		ActorType: actorType, ActorPublicID: actorID, Status: "pending",
		CreatedAt: time.Now(),
	}
	workflowStore.mu.Lock()
	workflowStore.changesets[cs.ID] = cs
	workflowStore.mu.Unlock()
	save()
	notifyGhoGemRevisionModeration(cs, t)
	json.NewEncoder(w).Encode(map[string]string{"status": "pending", "changeset_id": cs.ID})
}

func verificationAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !publicMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	if !allowWorkflowAction(r, 3, 24*time.Hour) {
		http.Error(w, `{"error":"verification rate limit"}`, http.StatusTooManyRequests)
		return
	}
	accountID := resolvedAccountID(r)
	if accountID == "" {
		http.Error(w, `{"error":"account required"}`, http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 24<<10)
	var req struct {
		ArtistName  string   `json:"artist_name"`
		Website     string   `json:"website"`
		SocialLinks []string `json:"social_links"`
		SoundIDs    []string `json:"sound_ids"`
		Evidence    string   `json:"evidence"`
		Statement   string   `json:"statement"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
		return
	}
	if len(req.ArtistName) == 0 || !validText(req.ArtistName, 160) || !validExternalURL(req.Website) ||
		!validText(req.Evidence, 4000) || !validText(req.Statement, 2000) || len(req.SoundIDs) == 0 || len(req.SoundIDs) > 20 || len(req.SocialLinks) > 10 {
		http.Error(w, `{"error":"invalid application"}`, http.StatusBadRequest)
		return
	}
	seenSounds := make(map[string]struct{}, len(req.SoundIDs))
	for _, value := range req.SoundIDs {
		if !validTrackID(value) {
			http.Error(w, `{"error":"invalid sound id"}`, 400)
			return
		}
		if _, exists := seenSounds[value]; exists {
			http.Error(w, `{"error":"duplicate sound id"}`, 400)
			return
		}
		seenSounds[value] = struct{}{}
	}
	for _, value := range append(append([]string{}, req.SocialLinks...), req.Website) {
		if len(value) > 512 || !validText(value, 512) || !validExternalURL(value) {
			http.Error(w, `{"error":"invalid link"}`, 400)
			return
		}
	}
	store.mu.RLock()
	for _, soundID := range req.SoundIDs {
		track := store.m[soundID]
		if track == nil || track.ModerationStatus != "published" {
			store.mu.RUnlock()
			http.Error(w, `{"error":"only published sounds can be verified"}`, http.StatusConflict)
			return
		}
	}
	store.mu.RUnlock()
	workflowStore.mu.Lock()
	for _, existing := range workflowStore.verifications {
		if existing != nil && existing.AccountID == accountID && existing.Status == "pending" {
			workflowStore.mu.Unlock()
			http.Error(w, `{"error":"pending application already exists"}`, http.StatusConflict)
			return
		}
	}
	app := &VerificationApplication{
		ID: randID(16), AccountID: accountID, ArtistName: req.ArtistName,
		Website: req.Website, SocialLinks: cloneStrings(req.SocialLinks), SoundIDs: cloneStrings(req.SoundIDs),
		Evidence: req.Evidence, Statement: req.Statement, Status: "pending", CreatedAt: time.Now(),
	}
	workflowStore.verifications[app.ID] = app
	workflowStore.mu.Unlock()
	save()
	json.NewEncoder(w).Encode(map[string]string{"status": "pending", "application_id": app.ID})
}
