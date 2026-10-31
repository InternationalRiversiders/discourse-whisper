# frozen_string_literal: true
class ScheduleWhisperNotificationRetries < ActiveRecord::Migration[7.2]
  def change
    add_column :river_whisper_events, :attempts, :integer, null: false, default: 0
    add_column :river_whisper_events, :next_attempt_at, :datetime, null: false, default: -> { "'1970-01-01'::timestamp" }
    add_column :river_whisper_events, :last_error_class, :string, limit: 100
    add_index :river_whisper_events, [:next_attempt_at, :id], where: 'notification_id IS NULL', name: 'whisper_events_due'
  end
end
