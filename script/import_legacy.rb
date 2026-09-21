# frozen_string_literal: true
path=ARGV.fetch(0)
raw=File.binread(path)
sha=Digest::SHA256.hexdigest(raw)
payload=JSON.parse(raw)
result=DiscourseWhisper::Importer.new(payload,directory:File.dirname(path),allow_missing_media:ENV['WHISPER_IMPORT_ALLOW_MISSING_MEDIA']=='1').run(sha:sha,apply:ENV['RIVER_IMPORT_APPLY']=='1',expected_sha:ENV['RIVER_IMPORT_SHA256'])
puts JSON.pretty_generate(result)
