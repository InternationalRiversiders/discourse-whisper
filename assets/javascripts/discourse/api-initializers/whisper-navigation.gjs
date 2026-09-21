import { apiInitializer } from "discourse/lib/api";
export default apiInitializer((api) => {
  // The shared Campus Life section owns application links when installed.
  if (api.container.lookup("service:site-settings").alumni_map_enabled) { return; }
  if (!api.container.lookup("service:site-settings").whisper_enabled) { return; }
  if (!api.getCurrentUser()?.whisper_member) { return; }
  api.addSidebarSection((BaseSection, BaseLink) => {
    return class extends BaseSection {
      get name() { return "whisper"; }
      get title() { return "树洞"; }
      get text() { return "树洞"; }
      get displaySection() { return true; }
      get links() { return [new (class extends BaseLink {
        get name() { return "whisper"; }
        get route() { return "whisper"; }
        get text() { return "树洞"; }
        get title() { return this.text; }
        get prefixType() { return "icon"; }
        get prefixValue() { return "leaf"; }
      })()]; }
    };
  });
});
