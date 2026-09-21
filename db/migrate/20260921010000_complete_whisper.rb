# frozen_string_literal: true
class CompleteWhisper < ActiveRecord::Migration[7.2]
  def change
    add_column :river_whisper_posts, :missing_media_count, :integer, null: false, default: 0
    add_index :river_whisper_posts, [:status, :created_at]
    add_index :river_whisper_posts, [:user_id, :created_at]
    add_index :river_whisper_comments, [:user_id, :created_at]
    create_table :river_whisper_inboxes do |t|
      t.bigint :user_id, null: false
      t.bigint :post_id
      t.bigint :comment_id
      t.string :kind, null: false
      t.text :message
      t.boolean :read, null: false, default: false
      t.boolean :historical, null: false, default: false
      t.string :event_key
      t.timestamps
    end
    add_index :river_whisper_inboxes, :event_key, unique: true
    add_index :river_whisper_inboxes, [:user_id, :read, :created_at], name: 'river_whisper_inbox_user'
  end
end
