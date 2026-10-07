package main

import (
	"crypto/hmac"
	"encoding/json"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	adminCookieName = "ghosou_admin_session"
	adminSessionTTL = time.Hour
)

var adminAuth = struct {
	mu       sync.Mutex
	sessions map[string]time.Time
	failures map[string][]time.Time
}{
	sessions: make(map[string]time.Time),
	failures: make(map[string][]time.Time),
}

func adminTokenConfigured() bool {
	token := strings.TrimSpace(os.Getenv("GHOSOU_ADMIN_TOKEN"))
	return len(token) >= 32 && validText(token, 4096)
}

func adminSessionOK(r *http.Request) bool {
	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie == nil || len(cookie.Value) < 32 || len(cookie.Value) > 128 {
		return false
	}
	now := time.Now()
	adminAuth.mu.Lock()
	expires, ok := adminAuth.sessions[cookie.Value]
	if !ok || !now.Before(expires) {
		delete(adminAuth.sessions, cookie.Value)
		ok = false
	}
	adminAuth.mu.Unlock()
	return ok
}

func adminRequestOK(r *http.Request) bool {
	return adminTokenOK(r) || adminSessionOK(r)
}

func adminTLSRequest(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	return strings.EqualFold(strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")), "https")
}

// Browser state-changing requests must originate from the same public origin.
// Requests without Origin/Referer remain usable for server-side administration
// with the X-Admin-Token header.
func adminMutationOriginOK(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	referer := strings.TrimSpace(r.Header.Get("Referer"))
	if origin == "" && referer == "" {
		return true
	}
	scheme := "http"
	if adminTLSRequest(r) {
		scheme = "https"
	}
	expected := scheme + "://" + r.Host
	if origin != "" {
		for _, allowed := range corsOrigins {
			if strings.EqualFold(origin, allowed) {
				return true
			}
		}
		host := strings.ToLower(strings.TrimSpace(r.Host))
		localHost := host == "localhost" || strings.HasPrefix(host, "localhost:") ||
			host == "127.0.0.1" || strings.HasPrefix(host, "127.0.0.1:") ||
			host == "[::1]" || strings.HasPrefix(host, "[::1]:")
		return localHost && strings.EqualFold(origin, expected)
	}
	for _, allowed := range corsOrigins {
		if strings.EqualFold(referer, allowed) || strings.HasPrefix(strings.ToLower(referer), strings.ToLower(allowed)+"/") {
			return true
		}
	}
	host := strings.ToLower(strings.TrimSpace(r.Host))
	localHost := host == "localhost" || strings.HasPrefix(host, "localhost:") ||
		host == "127.0.0.1" || strings.HasPrefix(host, "127.0.0.1:") ||
		host == "[::1]" || strings.HasPrefix(host, "[::1]:")
	return localHost && (strings.EqualFold(referer, expected) || strings.HasPrefix(strings.ToLower(referer), strings.ToLower(expected)+"/"))
}

func adminLoginAllowed(key string) bool {
	now := time.Now()
	cutoff := now.Add(-time.Minute)
	adminAuth.mu.Lock()
	defer adminAuth.mu.Unlock()
	hits := adminAuth.failures[key]
	kept := hits[:0]
	for _, at := range hits {
		if at.After(cutoff) {
			kept = append(kept, at)
		}
	}
	adminAuth.failures[key] = kept
	return len(kept) < 5
}

func recordAdminFailure(key string) {
	adminAuth.mu.Lock()
	adminAuth.failures[key] = append(adminAuth.failures[key], time.Now())
	adminAuth.mu.Unlock()
}

func adminLoginAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !adminMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	if !adminTokenConfigured() {
		http.Error(w, `{"error":"admin is not configured"}`, http.StatusServiceUnavailable)
		return
	}
	key := "admin:" + requestIP(r)
	if !adminLoginAllowed(key) {
		http.Error(w, `{"error":"too many attempts"}`, http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Token) > 4096 {
		http.Error(w, `{"error":"bad credentials"}`, http.StatusUnauthorized)
		recordAdminFailure(key)
		return
	}
	expected := strings.TrimSpace(os.Getenv("GHOSOU_ADMIN_TOKEN"))
	if !hmac.Equal([]byte(req.Token), []byte(expected)) {
		http.Error(w, `{"error":"bad credentials"}`, http.StatusUnauthorized)
		recordAdminFailure(key)
		return
	}
	session := randID(32)
	adminAuth.mu.Lock()
	adminAuth.sessions[session] = time.Now().Add(adminSessionTTL)
	adminAuth.mu.Unlock()
	http.SetCookie(w, &http.Cookie{
		Name:     adminCookieName,
		Value:    session,
		Path:     "/sound/",
		MaxAge:   int(adminSessionTTL / time.Second),
		HttpOnly: true,
		Secure:   adminTLSRequest(r),
		SameSite: http.SameSiteStrictMode,
	})
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func adminLogoutAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !adminMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	if cookie, err := r.Cookie(adminCookieName); err == nil {
		adminAuth.mu.Lock()
		delete(adminAuth.sessions, cookie.Value)
		adminAuth.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{
		Name: adminCookieName, Value: "", Path: "/sound/", MaxAge: -1,
		HttpOnly: true, Secure: adminTLSRequest(r), SameSite: http.SameSiteStrictMode,
	})
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func adminSummaryAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if r.Method != http.MethodGet || !adminRequestOK(r) {
		http.Error(w, `{"error":"admin required"}`, http.StatusForbidden)
		return
	}
	workflowStore.mu.RLock()
	pendingChanges := pendingChangesetsLocked()
	pendingVerifications := pendingVerificationsLocked()
	workflowStore.mu.RUnlock()
	store.mu.RLock()
	pendingSounds := make([]*adminSoundView, 0)
	for _, track := range store.m {
		if track != nil && track.ModerationStatus != "published" {
			pendingSounds = append(pendingSounds, adminSoundViewFor(track))
		}
	}
	store.mu.RUnlock()
	sortAdminSounds(pendingSounds)
	if len(pendingSounds) > 500 {
		pendingSounds = pendingSounds[:500]
	}
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sounds": pendingSounds, "changesets": pendingChanges, "verifications": pendingVerifications,
	})
}

func pendingChangesetsLocked() []*ChangeSet {
	items := make([]*ChangeSet, 0)
	for _, item := range workflowStore.changesets {
		if item != nil && item.Status == "pending" {
			copy := *item
			items = append(items, &copy)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.Before(items[j].CreatedAt) })
	return items
}

func pendingVerificationsLocked() []*VerificationApplication {
	items := make([]*VerificationApplication, 0)
	for _, item := range workflowStore.verifications {
		if item != nil && item.Status == "pending" {
			copy := *item
			copy.SocialLinks = cloneStrings(item.SocialLinks)
			copy.SoundIDs = cloneStrings(item.SoundIDs)
			items = append(items, &copy)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.Before(items[j].CreatedAt) })
	return items
}

func adminChangesetsAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if !adminRequestOK(r) {
		http.Error(w, `{"error":"admin required"}`, http.StatusForbidden)
		return
	}
	if r.Method == http.MethodGet {
		workflowStore.mu.RLock()
		items := make([]*ChangeSet, 0, len(workflowStore.changesets))
		for _, item := range workflowStore.changesets {
			if item != nil {
				copy := *item
				items = append(items, &copy)
			}
		}
		workflowStore.mu.RUnlock()
		sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.Before(items[j].CreatedAt) })
		if len(items) > 500 {
			items = items[:500]
		}
		json.NewEncoder(w).Encode(items)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"GET or POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !adminMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	var req struct {
		ID     string `json:"id"`
		Action string `json:"action"`
		Note   string `json:"note"`
	}
	if !decodeAdminAction(w, r, &req) {
		return
	}
	status, err := reviewChangeSet(req.ID, req.Action, req.Note)
	if err != nil {
		http.Error(w, `{"error":"`+jsonEscape(err.Error())+`"}`, http.StatusConflict)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"status": status})
}

func reviewChangeSet(id, action, note string) (string, error) {
	if len(id) < 16 || len(id) > 128 || !validText(note, 2000) {
		return "", errAdminInput
	}
	action = strings.ToLower(strings.TrimSpace(action))
	if action != "approve" && action != "reject" {
		return "", errAdminInput
	}
	workflowStore.mu.Lock()
	item, ok := workflowStore.changesets[id]
	if !ok || item == nil || item.Status != "pending" {
		workflowStore.mu.Unlock()
		return "", errAdminState
	}
	if action == "reject" {
		item.Status, item.ReviewedBy, item.ReviewNote, item.ReviewedAt = "rejected", "admin", note, time.Now()
		workflowStore.mu.Unlock()
		save()
		return "rejected", nil
	}
	item.Status = "reviewing"
	soundID, baseRevision, patch := item.SoundID, item.BaseRevision, item.Patch
	workflowStore.mu.Unlock()

	// Reacquire in workflow->store order, matching save(), so review and persistence
	// cannot deadlock with an upload or another admin operation.
	workflowStore.mu.Lock()
	item = workflowStore.changesets[id]
	store.mu.Lock()
	track, exists := store.m[soundID]
	if !exists || track == nil || track.CurrentRevisionID != baseRevision {
		if item != nil {
			item.Status, item.ReviewedBy, item.ReviewNote, item.ReviewedAt = "conflict", "admin", "base revision changed", time.Now()
		}
		store.mu.Unlock()
		workflowStore.mu.Unlock()
		save()
		return "conflict", errAdminState
	}
	applyTrackPatch(track, patch)
	track.Revision++
	track.CurrentRevisionID = revisionIDFor(track.ID, track.Revision)
	track.ModerationStatus, track.Status = "published", "published"
	if track.PublishedAt.IsZero() {
		track.PublishedAt = time.Now()
	}
	if item != nil {
		item.Status, item.ReviewedBy, item.ReviewNote, item.ReviewedAt = "approved", "admin", note, time.Now()
	}
	appendRevisionLocked(track, "admin", "", "approved changeset: "+id, "approved")
	store.mu.Unlock()
	workflowStore.mu.Unlock()
	save()
	return "approved", nil
}

func adminVerificationsAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if !adminRequestOK(r) {
		http.Error(w, `{"error":"admin required"}`, http.StatusForbidden)
		return
	}
	if r.Method == http.MethodGet {
		workflowStore.mu.RLock()
		items := make([]*VerificationApplication, 0, len(workflowStore.verifications))
		for _, item := range workflowStore.verifications {
			if item != nil {
				copy := *item
				copy.SocialLinks, copy.SoundIDs = cloneStrings(item.SocialLinks), cloneStrings(item.SoundIDs)
				items = append(items, &copy)
			}
		}
		workflowStore.mu.RUnlock()
		sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.Before(items[j].CreatedAt) })
		if len(items) > 500 {
			items = items[:500]
		}
		json.NewEncoder(w).Encode(items)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"GET or POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !adminMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	var req struct {
		ID string `json:"id"`
		Action string `json:"action"`
		Note string `json:"note"`
	}
	if !decodeAdminAction(w, r, &req) {
		return
	}
	verified, err := reviewVerification(req.ID, req.Action, req.Note)
	if err != nil {
		http.Error(w, `{"error":"`+jsonEscape(err.Error())+`"}`, http.StatusConflict)
		return
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"status": "ok", "verified_sounds": verified})
}

func reviewVerification(id, action, note string) (int, error) {
	if len(id) < 16 || len(id) > 128 || !validText(note, 2000) {
		return 0, errAdminInput
	}
	action = strings.ToLower(strings.TrimSpace(action))
	if action != "approve" && action != "reject" {
		return 0, errAdminInput
	}
	workflowStore.mu.Lock()
	app, ok := workflowStore.verifications[id]
	if !ok || app == nil || app.Status != "pending" {
		workflowStore.mu.Unlock()
		return 0, errAdminState
	}
	if action == "reject" {
		app.Status, app.ReviewedBy, app.ReviewNote, app.ReviewedAt = "rejected", "admin", note, time.Now()
		workflowStore.mu.Unlock()
		save()
		return 0, nil
	}
	store.mu.Lock()
	verified := 0
	for _, soundID := range app.SoundIDs {
		track := store.m[soundID]
		if track == nil || track.ModerationStatus != "published" {
			continue
		}
		track.AuthorVerified = true
		track.VerifiedAccountID = app.AccountID
		track.VerifiedArtistName = app.ArtistName
		track.UpdatedAt = time.Now()
		track.Revision++
		track.CurrentRevisionID = revisionIDFor(track.ID, track.Revision)
		appendRevisionLocked(track, "admin", "", "verified artist approval", "approved")
		verified++
	}
	app.Status, app.ReviewedBy, app.ReviewNote, app.ReviewedAt = "approved", "admin", note, time.Now()
	store.mu.Unlock()
	workflowStore.mu.Unlock()
	save()
	return verified, nil
}

func adminSoundAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	setCORS(w, r)
	if !adminRequestOK(r) {
		http.Error(w, `{"error":"admin required"}`, http.StatusForbidden)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/sound/api/admin/sounds/")
	if !validTrackID(id) {
		http.Error(w, `{"error":"bad sound id"}`, http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !adminMutationOriginOK(r) {
		http.Error(w, `{"error":"origin rejected"}`, http.StatusForbidden)
		return
	}
	var req struct {
		Action string `json:"action"`
		Note string `json:"note"`
	}
	if !decodeAdminAction(w, r, &req) {
		return
	}
	if !validText(req.Note, 2000) {
		http.Error(w, `{"error":"invalid note"}`, http.StatusBadRequest)
		return
	}
	status, err := setAdminSoundState(id, req.Action, req.Note)
	if err != nil {
		http.Error(w, `{"error":"`+jsonEscape(err.Error())+`"}`, http.StatusConflict)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"status": status})
}

func setAdminSoundState(id, action, note string) (string, error) {
	action = strings.ToLower(strings.TrimSpace(action))
	switch action {
	case "publish", "reject", "block", "unblock", "archive":
	default:
		return "", errAdminInput
	}
	workflowStore.mu.Lock()
	store.mu.Lock()
	track := store.m[id]
	if track == nil {
		store.mu.Unlock()
		workflowStore.mu.Unlock()
		return "", errAdminState
	}
	switch action {
	case "publish":
		track.ModerationStatus, track.Status = "published", "published"
		if track.Visibility == "private" {
			track.Visibility = "public"
		}
		if track.PublishedAt.IsZero() {
			track.PublishedAt = time.Now()
		}
	case "reject":
		track.ModerationStatus, track.Status = "rejected", "rejected"
	case "block":
		track.ModerationStatus, track.Status = "blocked", "blocked"
	case "unblock":
		track.ModerationStatus, track.Status = "pending", "pending"
	case "archive":
		track.ModerationStatus, track.Status, track.Visibility = "archived", "archived", "private"
	}
	track.UpdatedAt = time.Now()
	track.Revision++
	track.CurrentRevisionID = revisionIDFor(track.ID, track.Revision)
	appendRevisionLocked(track, "admin", "", "admin "+action+": "+note, action)
	store.mu.Unlock()
	workflowStore.mu.Unlock()
	save()
	return action, nil
}

var errAdminInput = &adminError{"invalid admin request"}
var errAdminState = &adminError{"item is missing or already reviewed"}

type adminError struct{ message string }

func (e *adminError) Error() string { return e.message }

func decodeAdminAction(w http.ResponseWriter, r *http.Request, target interface{}) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := json.NewDecoder(r.Body).Decode(target); err != nil {
		http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
		return false
	}
	return true
}

func jsonEscape(value string) string {
	b, _ := json.Marshal(value)
	if len(b) >= 2 {
		return string(b[1 : len(b)-1])
	}
	return ""
}
