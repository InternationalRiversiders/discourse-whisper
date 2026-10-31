# frozen_string_literal: true
class AddWhisperPublicAuthor < ActiveRecord::Migration[7.2]
  def change
    # Explicit opt-in: old comments' anonymous flag was not consistently populated.
    add_column :river_whisper_posts, :public_author, :boolean, null: false, default: false
    add_column :river_whisper_comments, :public_author, :boolean, null: false, default: false
  end
end
