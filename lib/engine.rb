# frozen_string_literal: true
module ::DiscourseWhisper
  class Engine < ::Rails::Engine
    engine_name "discourse-whisper"
    isolate_namespace ::DiscourseWhisper
    config.root = File.expand_path("..", __dir__)
  end
end
