import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import { App, Modal, Notice, Plugin, normalizePath } from "obsidian";

import {
  DEFAULT_SETTINGS,
  TranscribeerSettingTab,
  type TranscribeerSettings,
} from "./settings";

function readFileOptional(filePath: string): string | null {
  try {
    return fs.readFileSync(filePath, "utf-8").trim() || null;
  } catch {
    return null;
  }
}

interface SessionMeta {
  name?: string;
  participants?: { name?: string; isMe?: boolean }[];
}

const FORBIDDEN_FILENAME_CHARS = /[\\/:|?*<>"\n\r\t]/g;

/** Date folder name in dd-mm-yyyy form, e.g. 23-04-2026. */
function formatDateFolder(date: Date): string {
  const dd = String(date.getDate()).padStart(2, "0");
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const yyyy = String(date.getFullYear());
  return `${dd}-${mm}-${yyyy}`;
}

/** Strip characters that break Obsidian wikilinks / filenames. */
function sanitizeWikilink(name: string | undefined): string | null {
  if (!name) return null;
  const cleaned = name.replace(FORBIDDEN_FILENAME_CHARS, " ").replace(/\s+/g, " ").trim();
  return cleaned || null;
}

/** Persistent data: tracks which sessions have already been imported. */
interface PluginData {
  settings: TranscribeerSettings;
  importedSessions: string[];
}

export default class TranscribeerPlugin extends Plugin {
  settings: TranscribeerSettings = DEFAULT_SETTINGS;
  private importedSessions: Set<string> = new Set();
  private watcher: fs.FSWatcher | null = null;
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;

  async onload(): Promise<void> {
    await this.loadSettings();
    this.addSettingTab(new TranscribeerSettingTab(this.app, this));

    this.addCommand({
      id: "import-all",
      name: "Import all new sessions",
      callback: () => this.runImport(),
    });

    this.addCommand({
      id: "reimport-all",
      name: "Reimport all sessions (overwrite existing notes)",
      callback: () => this.runReimport(),
    });

    this.addRibbonIcon("file-down", "Transcribeer: import all new sessions", () =>
      this.runImport(),
    );

    if (this.settings.enabled) {
      this.app.workspace.onLayoutReady(() => {
        this.startWatcher();
        // Backfill existing sessions: fs.watch only fires on changes, so
        // sessions present before this load would otherwise never import.
        void this.runImport({ silent: true });
      });
    }
  }

  /** Public entry point for manual triggers — surfaces errors as notices. */
  async runImport(opts: { silent?: boolean } = {}): Promise<void> {
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) {
      new Notice(`Transcribeer: sessions dir not found: ${dir}`);
      return;
    }
    try {
      const imported = await this.importAllSessions();
      if (imported === 0 && !opts.silent) {
        new Notice("Transcribeer: nothing new to import");
      }
    } catch (err) {
      console.error("Transcribeer: import failed", err);
      new Notice(`Transcribeer: import failed — ${(err as Error).message}`);
    }
  }

  /** Show a confirmation modal, then delete every plugin-imported note and re-import. */
  async runReimport(): Promise<void> {
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) {
      new Notice(`Transcribeer: sessions dir not found: ${dir}`);
      return;
    }
    const toRemove = await this.countImportedNotes();
    const folder = normalizePath(this.settings.targetFolder);
    const confirmed = await new ConfirmModal(this.app, {
      title: "Reimport all sessions?",
      body:
        `This will delete ${toRemove} note${toRemove === 1 ? "" : "s"} in "${folder}" ` +
        `that were created by this plugin (identified by the source: frontmatter), ` +
        `then re-import every session from disk using the latest format. ` +
        `Hand-edited notes without the plugin's source marker are not touched. ` +
        `This cannot be undone.`,
      confirmText: "Delete and reimport",
      destructive: true,
    }).openAndAwait();
    if (!confirmed) return;

    try {
      const removed = await this.deleteImportedNotes();
      this.importedSessions.clear();
      await this.saveSettings();
      const imported = await this.importAllSessions();
      new Notice(
        `Transcribeer: reimported ${imported} session${imported === 1 ? "" : "s"}` +
          (removed > 0 ? ` (removed ${removed} stale note${removed === 1 ? "" : "s"})` : ""),
      );
    } catch (err) {
      console.error("Transcribeer: reimport failed", err);
      new Notice(`Transcribeer: reimport failed — ${(err as Error).message}`);
    }
  }

  private async countImportedNotes(): Promise<number> {
    const folder = normalizePath(this.settings.targetFolder);
    if (!this.app.vault.getAbstractFileByPath(folder)) return 0;
    const sessionsDir = this.resolveSessionsDir();
    const files = this.app.vault.getMarkdownFiles().filter((f) => f.path.startsWith(`${folder}/`));
    let count = 0;
    for (const file of files) {
      const content = await this.app.vault.read(file);
      const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
      if (match && match[1].includes(`source: ${sessionsDir}`)) count++;
    }
    return count;
  }

  /**
   * Delete notes in the target folder that we wrote, identified by the
   * `source:` frontmatter pointing into the configured sessions dir.
   * Hand-edited notes without that marker are left alone.
   */
  private async deleteImportedNotes(): Promise<number> {
    const folder = normalizePath(this.settings.targetFolder);
    const folderEntry = this.app.vault.getAbstractFileByPath(folder);
    if (!folderEntry) return 0;

    const sessionsDir = this.resolveSessionsDir();
    const files = this.app.vault.getMarkdownFiles().filter((f) => f.path.startsWith(`${folder}/`));
    let removed = 0;
    for (const file of files) {
      const content = await this.app.vault.read(file);
      const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
      if (!match) continue;
      if (match[1].includes(`source: ${sessionsDir}`)) {
        await this.app.vault.delete(file);
        removed++;
      }
    }
    await this.removeEmptySubfolders(folder);
    return removed;
  }

  private async removeEmptySubfolders(parent: string): Promise<void> {
    const folder = this.app.vault.getAbstractFileByPath(parent);
    if (!folder || !("children" in folder)) return;
    for (const child of [...(folder as { children: { path: string }[] }).children]) {
      const node = this.app.vault.getAbstractFileByPath(child.path);
      if (node && "children" in node) {
        const kids = (node as { children: unknown[] }).children;
        if (kids.length === 0) await this.app.vault.delete(node);
      }
    }
  }

  onunload(): void {
    this.stopWatcher();
  }

  // ── Settings persistence ───────────────────────────────────────────────────

  async loadSettings(): Promise<void> {
    const data: Partial<PluginData> = (await this.loadData()) ?? {};
    this.settings = { ...DEFAULT_SETTINGS, ...data.settings };
    this.importedSessions = new Set(data.importedSessions ?? []);
  }

  async saveSettings(): Promise<void> {
    const data: PluginData = {
      settings: this.settings,
      importedSessions: [...this.importedSessions],
    };
    await this.saveData(data);
  }

  // ── File watcher ───────────────────────────────────────────────────────────

  startWatcher(): void {
    this.stopWatcher();
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) {
      console.warn(`Transcribeer: sessions dir does not exist: ${dir}`);
      return;
    }

    this.watcher = fs.watch(dir, { recursive: true }, (_event, filename) => {
      if (!filename || !filename.endsWith("summary.md")) return;
      // Debounce: summary.md may be written incrementally
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = setTimeout(() => this.importAllSessions(), 2000);
    });

    console.log(`Transcribeer: watching ${dir}`);
  }

  stopWatcher(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
      console.log("Transcribeer: watcher stopped");
    }
  }

  // ── Import logic ───────────────────────────────────────────────────────────

  async importAllSessions(): Promise<number> {
    const dir = this.resolveSessionsDir();
    if (!fs.existsSync(dir)) return 0;

    let imported = 0;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (this.importedSessions.has(entry.name)) continue;

      const summaryPath = path.join(dir, entry.name, "summary.md");
      if (!fs.existsSync(summaryPath)) continue;

      const ok = await this.importSession(dir, entry.name);
      if (ok) imported++;
    }

    if (imported > 0) {
      await this.saveSettings();
      new Notice(`Transcribeer: imported ${imported} session${imported > 1 ? "s" : ""}`);
    }
    return imported;
  }

  private async importSession(dir: string, sessionName: string): Promise<boolean> {
    const sessionDir = path.join(dir, sessionName);
    const summary = readFileOptional(path.join(sessionDir, "summary.md"));
    if (!summary) return false;

    const transcript = readFileOptional(path.join(sessionDir, "transcript.txt"));
    const meta = this.readMeta(sessionDir);
    const date = this.parseSessionDate(sessionName);
    const title = this.buildTitle(date, meta?.name);
    const content = this.buildNoteContent(title, sessionDir, summary, transcript, date, meta);

    const dateFolder = normalizePath(
      `${this.settings.targetFolder}/${formatDateFolder(date)}`,
    );
    if (!this.app.vault.getAbstractFileByPath(dateFolder)) {
      await this.app.vault.createFolder(dateFolder);
    }

    const notePath = normalizePath(`${dateFolder}/${title}.md`);
    if (this.app.vault.getAbstractFileByPath(notePath)) {
      this.importedSessions.add(sessionName);
      return false;
    }

    await this.app.vault.create(notePath, content);
    this.importedSessions.add(sessionName);
    console.log(`Transcribeer: imported ${sessionName} → ${notePath}`);
    return true;
  }

  private readMeta(sessionDir: string): SessionMeta | null {
    const raw = readFileOptional(path.join(sessionDir, "meta.json"));
    if (!raw) return null;
    try {
      return JSON.parse(raw) as SessionMeta;
    } catch {
      return null;
    }
  }

  private buildNoteContent(
    title: string,
    sessionDir: string,
    summary: string,
    transcript: string | null,
    date: Date,
    meta: SessionMeta | null,
  ): string {
    const tags = this.settings.tags
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);

    const participants = (meta?.participants ?? [])
      .map((p) => sanitizeWikilink(p.name))
      .filter((n): n is string => Boolean(n));
    const participantLinks = participants.map((n) => `"[[${n}]]"`);

    const frontmatter: string[] = [
      "---",
      `date: ${date.toISOString().slice(0, 19)}`,
      `tags: [${tags.join(", ")}]`,
      `source: ${sessionDir}`,
    ];
    if (participantLinks.length > 0) {
      frontmatter.push(`participants: [${participantLinks.join(", ")}]`);
    }
    frontmatter.push("---", "");

    const lines: string[] = [...frontmatter, `# ${title}`, ""];
    if (participants.length > 0) {
      lines.push(
        "## Participants",
        participants.map((n) => `[[${n}]]`).join(" · "),
        "",
      );
    }
    lines.push(summary);

    if (transcript) {
      const blockquoted = transcript
        .split("\n")
        .map((l) => `> ${l}`)
        .join("\n");
      lines.push("", "---", "", "> [!note]- Full Transcript", blockquoted);
    }

    return lines.join("\n") + "\n";
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private resolveSessionsDir(): string {
    return this.settings.sessionsDir.replace(/^~/, os.homedir());
  }

  /** Filesystem-safe title. Obsidian forbids `: \ / | ? * < > "` in filenames. */
  private buildTitle(date: Date, name?: string): string {
    const day = date.toISOString().slice(0, 10);
    const hh = String(date.getHours()).padStart(2, "0");
    const mm = String(date.getMinutes()).padStart(2, "0");
    const stem = sanitizeWikilink(name) ?? "Meeting";
    return `${stem} ${day} ${hh}-${mm}`;
  }

  /**
   * Parse session folder name (YYYY-MM-DD-HHMM) into a Date.
   * Falls back to current time if parsing fails.
   */
  private parseSessionDate(name: string): Date {
    const match = name.match(/^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/);
    if (!match) return new Date();
    const [, year, month, day, hour, minute] = match;
    return new Date(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute));
  }
}

interface ConfirmOptions {
  title: string;
  body: string;
  confirmText: string;
  destructive?: boolean;
}

class ConfirmModal extends Modal {
  private result = false;
  private resolver: ((value: boolean) => void) | null = null;

  constructor(
    app: App,
    private opts: ConfirmOptions,
  ) {
    super(app);
  }

  openAndAwait(): Promise<boolean> {
    return new Promise((resolve) => {
      this.resolver = resolve;
      this.open();
    });
  }

  onOpen(): void {
    this.titleEl.setText(this.opts.title);
    this.contentEl.createEl("p", { text: this.opts.body });

    const buttons = this.contentEl.createDiv({ cls: "modal-button-container" });
    const cancel = buttons.createEl("button", { text: "Cancel" });
    cancel.addEventListener("click", () => this.close());

    const confirm = buttons.createEl("button", { text: this.opts.confirmText });
    if (this.opts.destructive) confirm.addClass("mod-warning");
    else confirm.addClass("mod-cta");
    confirm.addEventListener("click", () => {
      this.result = true;
      this.close();
    });
  }

  onClose(): void {
    this.contentEl.empty();
    this.resolver?.(this.result);
    this.resolver = null;
  }
}
