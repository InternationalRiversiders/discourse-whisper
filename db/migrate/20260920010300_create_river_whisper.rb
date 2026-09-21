# frozen_string_literal: true
class CreateRiverWhisper < ActiveRecord::Migration[7.2]
  def change
    create_table :river_whisper_commands do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :river_whisper_commands, [:user_id, :key], unique: true
    create_table :river_whisper_events do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :text, null: false
      t.string :path, null: false
      t.bigint :notification_id
      t.timestamps
    end
    add_index :river_whisper_events, :key, unique: true
    create_table :river_whisper_audits do |t|
      t.bigint :user_id, null: false
      t.string :action, null: false
      t.string :target_kind
      t.bigint :target_id
      t.string :reason, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    create_table :river_whisper_legacies do |t|
      t.string :source, null: false
      t.string :legacy_id, null: false
      t.string :target_kind
      t.bigint :target_id
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :river_whisper_legacies, [:source, :legacy_id], unique: true
    create_table :river_whisper_media do |t|
      t.bigint :user_id, null: false
      t.string :token, null: false
      t.binary :bytes, null: false
      t.integer :size, null: false
      t.timestamps
    end
    add_index :river_whisper_media, :token, unique: true
    create_table :river_whisper_reactions do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.integer :value, null: false
      t.timestamps
    end
    add_index :river_whisper_reactions, [:user_id, :target_kind, :target_id], unique: true, name: 'river_whisper_reaction_unique'
    add_check_constraint :river_whisper_reactions, 'value IN (-1,1)', name: 'river_whisper_reaction_value'
    create_table :river_whisper_reports do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.string :reason, null: false
      t.datetime :handled_at
      t.timestamps
    end
    add_index :river_whisper_reports, [:user_id, :target_kind, :target_id], unique: true, name: 'river_whisper_report_unique'
    create_table :river_whisper_comments do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.bigint :parent_id
      t.text :body, null: false
      t.boolean :anonymous, null: false, default: false
      t.string :status, null: false, default: 'visible'
      t.decimal :rating, precision: 3, scale: 1
      t.jsonb :media_ids, null: false, default: []
      t.timestamps
    end
    add_index :river_whisper_comments, [:target_kind, :target_id, :id], name: 'river_whisper_comment_target'
    add_foreign_key :river_whisper_comments, :river_whisper_comments, column: :parent_id
    add_check_constraint :river_whisper_comments, 'rating IS NULL OR (rating >= 0.5 AND rating <= 5)', name: 'river_whisper_comment_rating'
    create_table :river_whisper_posts do |t|
      t.bigint :user_id, null:false
      t.string :public_code, null:false
      t.string :title
      t.text :body, null:false
      t.string :status, null:false, default:'visible'
      t.jsonb :media_ids, null:false, default:[]
      t.datetime :last_comment_at
      t.timestamps
    end
    add_index :river_whisper_posts, :public_code, unique:true
    create_table :river_whisper_aliases do |t|
      t.bigint :post_id, null:false
      t.bigint :user_id, null:false
      t.integer :ordinal, null:false
      t.timestamps
    end
    add_index :river_whisper_aliases, [:post_id,:user_id], unique:true
    add_index :river_whisper_aliases, [:post_id,:ordinal], unique:true
    add_foreign_key :river_whisper_aliases, :river_whisper_posts, column: :post_id
    create_table :river_whisper_bans do |t|
      t.bigint :user_id, null:false
      t.string :reason, null:false
      t.timestamps
    end
    add_index :river_whisper_bans, :user_id, unique:true
  end
end
