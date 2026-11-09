// nascar - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/filesystem.h>
#include <rex/rex_app.h>

#include <filesystem>

class NascarApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<NascarApp>(new NascarApp(ctx, "nascar",
        PPCImageConfig));
  }

  // Override virtual hooks for customization:
  // void OnPostInitLogging() override {}
  // void OnPreSetup(rex::RuntimeConfig& config) override {}
  // void OnLoadXexImage(std::string& xex_image) override {}
  // void OnPostLoadXexImage() override {}
  // void OnPostSetup() override {}
  // void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  // std::unique_ptr<rex::ui::ImGuiDialog> CreateAchievementsOverlay() override;
  // std::unique_ptr<rex::ui::AchievementNotificationDialog>
  // CreateAchievementNotificationDialog() override;
  // void OnShutdown() override {}
  // Default folders, relative to the exe (recomp\nascar\out\build\<preset>\):
  //   recomp\game   - disc contents extracted from the ISO
  //   recomp\update - empty title-update drive (so update: lookups get
  //                   "file not found" rather than "device not found")
  // ReXApp resolves paths before it reads nascar.toml, so these cannot live in
  // the config file. --game_data_root / --update_data_root still override them.
  void OnConfigurePaths(rex::PathConfig& paths) override {
    const auto recomp = rex::filesystem::GetExecutableFolder() / ".." / ".." / ".." / "..";
    if (paths.game_data_root.empty()) {
      paths.game_data_root = std::filesystem::weakly_canonical(recomp / "game");
    }
    if (paths.update_data_root.empty()) {
      paths.update_data_root = std::filesystem::weakly_canonical(recomp / "update");
    }
  }
};
