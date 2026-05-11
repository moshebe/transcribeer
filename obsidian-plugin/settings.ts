import { App, PluginSettingTab, Setting } from "obsidian";
import type TranscribeerPlugin from "./main";

export interface TranscribeerSettings {
  enabled: boolean;
  sessionsDir: string;
  targetFolder: string;
  tags: string;
}

export const DEFAULT_SETTINGS: TranscribeerSettings = {
  enabled: false,
  sessionsDir: "~/.transcribeer/sessions",
  targetFolder: "Transcriptions",
  tags: "transcribeer, meeting",
};

export class TranscribeerSettingTab extends PluginSettingTab {
  plugin: TranscribeerPlugin;

  constructor(app: App, plugin: TranscribeerPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl("h2", { text: "Transcribeer" });

    new Setting(containerEl)
      .setName("Import now")
      .setDesc("Scan the sessions directory and import any new sessions.")
      .addButton((btn) =>
        btn
          .setButtonText("Import all")
          .setCta()
          .onClick(() => this.plugin.runImport()),
      );

    new Setting(containerEl)
      .setName("Reimport all (overwrite)")
      .setDesc(
        "Delete every plugin-imported note in the target folder and recreate them " +
          "with the latest format. Notes without the plugin's source frontmatter are left alone.",
      )
      .addButton((btn) =>
        btn
          .setButtonText("Reimport all")
          .setWarning()
          .onClick(() => this.plugin.runReimport()),
      );

    new Setting(containerEl)
      .setName("Enable auto-import")
      .setDesc("Watch for new transcribeer sessions and import them automatically.")
      .addToggle((toggle) =>
        toggle.setValue(this.plugin.settings.enabled).onChange(async (value) => {
          this.plugin.settings.enabled = value;
          await this.plugin.saveSettings();
          if (value) {
            this.plugin.startWatcher();
            void this.plugin.importAllSessions();
          } else {
            this.plugin.stopWatcher();
          }
        })
      );

    new Setting(containerEl)
      .setName("Sessions directory")
      .setDesc("Path to the transcribeer sessions directory.")
      .addText((text) =>
        text
          .setPlaceholder("~/.transcribeer/sessions")
          .setValue(this.plugin.settings.sessionsDir)
          .onChange(async (value) => {
            this.plugin.settings.sessionsDir = value;
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Target folder")
      .setDesc("Folder in your vault where imported notes are created.")
      .addText((text) =>
        text
          .setPlaceholder("Transcriptions")
          .setValue(this.plugin.settings.targetFolder)
          .onChange(async (value) => {
            this.plugin.settings.targetFolder = value;
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Tags")
      .setDesc("Comma-separated tags added to frontmatter of imported notes.")
      .addText((text) =>
        text
          .setPlaceholder("transcribeer, meeting")
          .setValue(this.plugin.settings.tags)
          .onChange(async (value) => {
            this.plugin.settings.tags = value;
            await this.plugin.saveSettings();
          })
      );
  }
}
