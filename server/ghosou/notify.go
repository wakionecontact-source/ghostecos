package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const ghoGemModerationAlertCooldown = 15 * time.Minute

var ghoGemModerationAlertState = struct {
	sync.Mutex
	sent map[string]time.Time
}{
	sent: make(map[string]time.Time),
}

func moderationAlertText(value string, maxRunes int) string {
	value = strings.Join(strings.Fields(strings.TrimSpace(value)), " ")
	if value == "" {
		return ""
	}
	runes := []rune(value)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "..."
	}
	return value
}

func claimGhoGemModerationAlert(key string) bool {
	now := time.Now()
	ghoGemModerationAlertState.Lock()
	defer ghoGemModerationAlertState.Unlock()
	for sentKey, sentAt := range ghoGemModerationAlertState.sent {
		if now.Sub(sentAt) >= ghoGemModerationAlertCooldown {
			delete(ghoGemModerationAlertState.sent, sentKey)
		}
	}
	if sentAt, ok := ghoGemModerationAlertState.sent[key]; ok && now.Sub(sentAt) < ghoGemModerationAlertCooldown {
		return false
	}
	ghoGemModerationAlertState.sent[key] = now
	return true
}

func changedRevisionFields(patch TrackPatch) string {
	fields := make([]string, 0, 18)
	if patch.Title != nil {
		fields = append(fields, "название")
	}
	if patch.Artist != nil {
		fields = append(fields, "исполнитель")
	}
	if patch.Album != nil {
		fields = append(fields, "альбом")
	}
	if patch.Genre != nil {
		fields = append(fields, "жанр")
	}
	if patch.Description != nil {
		fields = append(fields, "описание")
	}
	if patch.Lyrics != nil {
		fields = append(fields, "текст")
	}
	if patch.Kind != nil {
		fields = append(fields, "тип")
	}
	if patch.AuthorMode != nil || patch.AuthorName != nil || patch.AnonAuthorID != nil {
		fields = append(fields, "авторство")
	}
	if patch.Genres != nil {
		fields = append(fields, "категории")
	}
	if patch.Tags != nil {
		fields = append(fields, "теги")
	}
	if patch.Language != nil {
		fields = append(fields, "язык")
	}
	if patch.SourceType != nil {
		fields = append(fields, "источник")
	}
	if patch.License != nil || patch.LicenseURL != nil {
		fields = append(fields, "лицензия")
	}
	if patch.Visibility != nil {
		fields = append(fields, "видимость")
	}
	if patch.DownloadAllowed != nil {
		fields = append(fields, "скачивание")
	}
	if len(fields) == 0 {
		return "не указаны"
	}
	return strings.Join(fields, ", ")
}

func notifyGhoGemRevisionModeration(changeSet *ChangeSet, track *Track) {
	if changeSet == nil || track == nil || strings.TrimSpace(changeSet.ID) == "" {
		return
	}
	token := strings.TrimSpace(os.Getenv("TELEGRAM_TOKEN"))
	adminID := strings.TrimSpace(os.Getenv("ADMIN_USER_ID"))
	if token == "" || adminID == "" {
		return
	}
	adminIDInt, err := strconv.ParseInt(adminID, 10, 64)
	if err != nil {
		log.Printf("GhoGem moderation alert skipped: invalid ADMIN_USER_ID")
		return
	}
	if !claimGhoGemModerationAlert("revision:" + changeSet.ID) {
		return
	}

	title := moderationAlertText(track.Title, 160)
	if title == "" {
		title = moderationAlertText(track.Filename, 160)
	}
	if title == "" {
		title = "без названия"
	}
	artist := moderationAlertText(track.Artist, 160)
	if artist == "" {
		artist = "не указан"
	}
	summary := moderationAlertText(changeSet.Summary, 500)
	if summary == "" {
		summary = "не указано"
	}
	reason := moderationAlertText(changeSet.Reason, 500)
	if reason == "" {
		reason = "не указана"
	}
	baseRevision := moderationAlertText(changeSet.BaseRevision, 120)
	if baseRevision == "" {
		baseRevision = "не указана"
	}
	text := fmt.Sprintf(
		"GhoGem: нужна модерация ревизии\n\n"+
			"Трек: %s\n"+
			"Исполнитель: %s\n"+
			"ID трека: %s\n"+
			"ID заявки: %s\n"+
			"Базовая ревизия: %s\n"+
			"Изменяемые поля: %s\n"+
			"Описание изменений: %s\n"+
			"Причина: %s\n\n"+
			"Открыть админку: https://ghostecos.duckdns.org/sound/admin",
		title,
		artist,
		moderationAlertText(changeSet.SoundID, 120),
		moderationAlertText(changeSet.ID, 120),
		baseRevision,
		changedRevisionFields(changeSet.Patch),
		summary,
		reason,
	)
	payload, err := json.Marshal(map[string]interface{}{
		"chat_id":                  adminIDInt,
		"text":                     text,
		"disable_web_page_preview": true,
	})
	if err != nil {
		log.Printf("GhoGem moderation alert skipped: could not encode payload")
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(
			ctx,
			http.MethodPost,
			"https://api.telegram.org/bot"+token+"/sendMessage",
			bytes.NewReader(payload),
		)
		if err != nil {
			log.Printf("GhoGem moderation alert request build failed")
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Printf("GhoGem moderation alert request failed: %v", err)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
			log.Printf("GhoGem moderation alert returned %s", resp.Status)
		}
	}()
}

func notifyGhoGemTrackModeration(track *Track) {
	if track == nil || strings.TrimSpace(track.ID) == "" {
		return
	}
	token := strings.TrimSpace(os.Getenv("TELEGRAM_TOKEN"))
	adminID := strings.TrimSpace(os.Getenv("ADMIN_USER_ID"))
	if token == "" || adminID == "" {
		return
	}
	adminIDInt, err := strconv.ParseInt(adminID, 10, 64)
	if err != nil {
		log.Printf("GhoGem moderation alert skipped: invalid ADMIN_USER_ID")
		return
	}
	if !claimGhoGemModerationAlert("track:" + track.ID) {
		return
	}
	title := moderationAlertText(track.Title, 160)
	if title == "" {
		title = moderationAlertText(track.Filename, 160)
	}
	if title == "" {
		title = "без названия"
	}
	artist := moderationAlertText(track.Artist, 160)
	if artist == "" {
		artist = "не указан"
	}
	reason := "GhoGem нашёл похожие публикации или автоматическая проверка была недоступна"
	if track.PublicationAnalysis != nil && track.PublicationAnalysis.Warning != "" {
		reason = moderationAlertText(track.PublicationAnalysis.Warning, 500)
	}
	text := fmt.Sprintf(
		"GhoGem: новая публикация на модерацию\n\n"+
			"Трек: %s\n"+
			"Исполнитель: %s\n"+
			"ID трека: %s\n"+
			"Причина: %s\n\n"+
			"Открыть админку: https://ghostecos.duckdns.org/sound/admin",
		title, artist, moderationAlertText(track.ID, 120), reason,
	)
	payload, err := json.Marshal(map[string]interface{}{
		"chat_id": adminIDInt,
		"text": text,
		"disable_web_page_preview": true,
	})
	if err != nil {
		log.Printf("GhoGem moderation alert skipped: could not encode payload")
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.telegram.org/bot"+token+"/sendMessage", bytes.NewReader(payload))
		if err != nil {
			log.Printf("GhoGem moderation alert request build failed")
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Printf("GhoGem moderation alert request failed: %v", err)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
			log.Printf("GhoGem moderation alert returned %s", resp.Status)
		}
	}()
}
