//go:build windows

package main

// The improvement loop on Windows (#184): every ImproveBatch new utterances,
// while Koe is idle, the recent transcripts go to ImproveCommand (by default
// the user's own Claude Code). The answer adds misrecognized terms to the
// personal glossary and a judgement to each history record. Off by default;
// turned on from the tray only after a confirmation that shows what is sent and
// where. Logs hold counts only, never text.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/chaspy/koe/windows/core"
)

const improveTimeout = 5 * time.Minute

func (a *App) improveCandidatesPath() string {
	return filepath.Join(a.roamDir, "glossary_candidates.json")
}
func (a *App) improvePreviewPath() string { return filepath.Join(a.localDir, "improve_preview.txt") }

// knownTerms: the terms already in the personal glossary (sent so the LLM does not repeat them).
func (a *App) knownTerms() []string {
	var out []string
	for _, e := range core.ReadGlossaryFile(a.glossaryPath()) {
		out = append(out, e.Term)
	}
	return out
}

// sessionHumans reads the Claude Code session logs around the batch (local files only).
func (a *App) sessionHumans(batch []core.ImproveItem) []core.SessionHuman {
	root := filepath.Join(os.Getenv("USERPROFILE"), ".claude", "projects")
	return core.LoadSessionLogs(root, core.ImproveSince(batch, time.Now()))
}

// maybeImprove starts a run in the background when the loop is on, Koe is idle
// and enough utterances are waiting (force: any waiting, from the menu).
func (a *App) maybeImprove(force bool) {
	busy := a.recording.Load() || a.processing.Load() > 0
	if !a.improveMaySend() || busy || !a.improveRunning.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer a.improveRunning.Store(false)
		defer a.recoverLog("improve")
		items, paths := core.LoadImproveItems(a.historyDir())
		batch := core.ImproveBatch(items)
		if !core.ShouldRunImprove(a.improveOn.Load(), false, len(batch), a.cfg.ImproveBatch, force) {
			return
		}
		a.runImprove(batch, paths)
	}()
}

func (a *App) runImprove(batch []core.ImproveItem, paths map[string]string) {
	started := time.Now()
	req := core.ImproveRequest(batch, a.knownTerms(), a.sessionHumans(batch))
	ans, err := a.askImprove(req)
	// the LLM sometimes leaves out the judgements: ask once more, then leave the batch for the next run
	if err == nil && len(ans.Judgements) == 0 {
		ans, err = a.askImprove(req)
	}
	if err == nil && len(ans.Judgements) == 0 {
		err = errors.New("no judgements")
	}
	if err != nil {
		a.log.Printf("improve_failed items=%d err=%s", len(batch), shorten(err.Error(), 120))
		return
	}
	judged, corrected := core.MarkImproveItems(paths, batch, ans)
	cand, promote := core.MergeImproveTerms(core.ReadTermCandidates(a.improveCandidatesPath()), ans.Terms)
	if err := core.WriteTermCandidates(a.improveCandidatesPath(), cand); err != nil {
		a.log.Printf("improve_candidates_save_failed %v", err)
	}
	added := 0
	if len(promote) > 0 {
		old, _ := os.ReadFile(a.glossaryPath())
		text, newTerms := core.ApplyImprovePromotions(string(old), promote)
		if err := os.WriteFile(a.glossaryPath(), []byte(text), 0o600); err != nil {
			a.log.Printf("improve_glossary_save_failed %v", err)
		}
		added = len(newTerms)
	}
	a.log.Printf("improve items=%d judged=%d corrected=%d promoted=%d added=%d ms=%d",
		len(batch), judged, corrected, len(promote), added, time.Since(started).Milliseconds())
}

// askImprove runs ImproveCommand with the request on stdin and reads its answer.
func (a *App) askImprove(req string) (core.ImproveAnswer, error) {
	ctx, cancel := context.WithTimeout(context.Background(), improveTimeout)
	defer cancel()
	// cmd /c finds claude.cmd (npm) and other commands on the user's PATH, like a terminal would
	cmd := exec.CommandContext(ctx, "cmd", "/c", a.cfg.ImproveCommand)
	hideWindow(cmd)
	cmd.Stdin = strings.NewReader(req)
	out, err := cmd.Output()
	if ctx.Err() != nil {
		return core.ImproveAnswer{}, errors.New("timeout")
	}
	if err != nil {
		return core.ImproveAnswer{}, err
	}
	// kept for looking into a failed parse, next to the history (local only)
	_ = os.WriteFile(filepath.Join(a.localDir, "improve_last_response.txt"), out, 0o600)
	return core.ParseImproveAnswer(string(out))
}

// toggleImprove: turning on always shows what is sent and where first.
func (a *App) toggleImprove() {
	defer a.recoverLog("improve_toggle")
	if a.improveOn.Load() {
		a.setImprove(false, "menu")
		return
	}
	if !a.askImproveConsent() {
		a.log.Printf("improve_declined via=menu reason=confirm")
		return
	}
	a.setImprove(true, "menu")
	a.maybeImprove(false)
}

// askImproveConsent shows what is sent and where (default answer: No). A yes is
// recorded for this exact improveCommand in improve_consent.json.
func (a *App) askImproveConsent() bool {
	text := "発話の文字起こし（直近の最大 60 件）と、Claude Code のセッション記録の該当部分（送った文・返答・次の発話）を、次の送り先に送って、自分の辞書を育てます。音声は送りません。\n" +
		"ロック録音と、文字にできなかった録音は送りません。\n\n" +
		"送り先: " + a.cfg.ImproveTarget() + "\n\n" +
		"送る内容は、メニューの「改善ループで送る内容を見る」で、送る前に確かめられます。\n\nオンにしますか？"
	if messageBoxResult("Koe: 改善ループをオンにしますか？", text, core.MBYesNo|core.MBIconInfo|core.MBDefButton2|core.MBTopmost) != core.IDYes {
		return false
	}
	if err := core.WriteImproveConsent(a.improveConsentPath(), a.cfg.ImproveCommand, time.Now()); err != nil {
		a.log.Printf("improve_consent_save_failed %v", err)
	}
	return true
}

func (a *App) improveConsentPath() string { return filepath.Join(a.roamDir, "improve_consent.json") }

// improveMaySend: on, and the user agreed to this command (writing config.json alone is not enough).
func (a *App) improveMaySend() bool {
	return core.ImproveMaySend(a.improveOn.Load(), core.ReadImproveConsent(a.improveConsentPath()), a.cfg.ImproveCommand)
}

// checkImproveConsent runs at start: improveEnabled was written as true in
// config.json (or the destination changed) without a yes from the user. Ask
// once; nothing is sent before the answer, and No turns the loop off again.
func (a *App) checkImproveConsent() {
	defer a.recoverLog("improve_consent")
	if !core.ImproveNeedsConsent(a.improveOn.Load(), core.ReadImproveConsent(a.improveConsentPath()), a.cfg.ImproveCommand) {
		return
	}
	a.log.Printf("improve_consent_asked via=config")
	if !a.askImproveConsent() {
		a.log.Printf("improve_declined via=config reason=confirm")
		a.setImprove(false, "config")
		return
	}
	a.log.Printf("improve_enabled_via via=config")
}

func (a *App) setImprove(on bool, via string) {
	if err := core.SetConfigValue(a.configPath(), "improveEnabled", on); err != nil {
		a.log.Printf("improve_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.improveOn.Store(on)
	if on {
		a.log.Printf("improve_enabled_via via=%s", via)
	} else {
		a.log.Printf("improve_disabled via=%s", via)
	}
	a.renderImprove()
}

// previewImprove writes the next request to a text file and opens it in
// Notepad. Nothing is sent. The file is next to the history (which already
// holds the same text) and is removed at the next start.
func (a *App) previewImprove() {
	defer a.recoverLog("improve_preview")
	items, _ := core.LoadImproveItems(a.historyDir())
	batch := core.ImproveBatch(items)
	a.log.Printf("improve_preview count=%d", len(batch))
	if len(batch) == 0 {
		messageBox("Koe", "まだ送る発話がありません（履歴の保存がオンなら、話した分がたまります）。", core.MBIconInfo)
		return
	}
	head := "# 改善ループで次に送る内容（まだ送っていません）\r\n# 送り先: " + a.cfg.ImproveTarget() + "\r\n# 音声は送りません。このファイルは次に Koe を起動したときに消えます。\r\n\r\n"
	body := strings.ReplaceAll(core.ImproveRequest(batch, a.knownTerms(), a.sessionHumans(batch)), "\n", "\r\n")
	if err := os.WriteFile(a.improvePreviewPath(), []byte(head+body), 0o600); err != nil {
		a.log.Printf("improve_preview_failed %v", err)
		return
	}
	_ = exec.Command("notepad.exe", a.improvePreviewPath()).Start()
}

// renderImprove: when off, the menu says what turning it on does.
func (a *App) renderImprove() {
	mi := a.tray.improve
	if mi == nil {
		return
	}
	if a.improveOn.Load() {
		mi.SetTitle("使うほど賢くする（改善ループ）")
		mi.Check()
	} else {
		mi.SetTitle("改善ループ: オフ（有効にすると使うほど賢くなります）")
		mi.Uncheck()
	}
	// 提案を出さない: ループがオフで、まだ決めていない間だけ出す
	if n := a.tray.suggestNever; n != nil {
		if a.improveOn.Load() || !a.improveUndecided() {
			n.Hide()
		} else {
			n.Show()
			if core.ReadSuggestState(a.suggestStatePath()).NeverAgain {
				n.Check()
			} else {
				n.Uncheck()
			}
		}
	}
}

func (a *App) suggestStatePath() string { return filepath.Join(a.roamDir, "improve_suggest.json") }

// improveUndecided: improveEnabled was never written to config.json (by the tray, the user or an admin).
func (a *App) improveUndecided() bool { return !core.ConfigHasKey(a.configPath(), "improveEnabled") }

// noteImprovePaste counts a paste with the loop off and shows the one-time
// suggestion when it is due (in the tray status, like the other hints; never a dialog).
func (a *App) noteImprovePaste() {
	if a.improveOn.Load() || !a.improveUndecided() {
		return
	}
	s := core.SuggestPasted(core.ReadSuggestState(a.suggestStatePath()))
	if core.ShouldSuggestImprove(s, time.Now(), true) {
		a.log.Printf("improve_suggested shown=%d pasted_total=%d", s.Shown+1, s.PastedTotal)
		a.setError(core.SuggestText(s), false)
		s = core.SuggestShown(s, time.Now())
	}
	if err := core.WriteSuggestState(a.suggestStatePath(), s); err != nil {
		a.log.Printf("improve_suggest_save_failed %v", err)
	}
}

// toggleSuggestNever: the tray item 「改善ループの提案を出さない」.
func (a *App) toggleSuggestNever() {
	defer a.recoverLog("improve_suggest_never")
	s := core.ReadSuggestState(a.suggestStatePath())
	s.NeverAgain = !s.NeverAgain
	if err := core.WriteSuggestState(a.suggestStatePath(), s); err != nil {
		a.log.Printf("improve_suggest_save_failed %v", err)
	}
	if s.NeverAgain {
		a.log.Printf("improve_declined via=menu reason=never")
	}
	a.renderImprove()
}
