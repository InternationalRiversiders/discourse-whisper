# frozen_string_literal: true
# name: discourse-whisper
# about: 树洞 — Riverside native community application
# version: 0.2.0
# authors: Riverside
# url: https://github.com/InternationalRiversiders/discourse-whisper
# required_version: 2026.9.0-latest

enabled_site_setting :whisper_enabled
register_asset "stylesheets/whisper.scss"
%w[leaf reply thumbs-up thumbs-down flag trash-can plus magnifying-glass link shield-halved eye chevron-left chevron-right bell lock].each { |name| register_svg_icon name }
require_relative "lib/engine"
after_initialize do
  require_relative "lib/core"
  require_relative "lib/business"
  require_relative "lib/importer"
  require_relative "lib/user_lifecycle"
  add_to_serializer(:current_user, :whisper_member) { SiteSetting.whisper_enabled && DiscourseWhisper::Access.member?(object) }

  Discourse::Application.routes.append { mount DiscourseWhisper::Engine, at: "/whisper" }
end
