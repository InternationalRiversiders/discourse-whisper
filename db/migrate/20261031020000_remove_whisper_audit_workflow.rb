# frozen_string_literal: true
class RemoveWhisperAuditWorkflow < ActiveRecord::Migration[7.2]
  def up
    execute "DELETE FROM river_whisper_commands WHERE result ? 'identity_user_id'"
    execute "DELETE FROM river_whisper_legacies WHERE source IN ('IdentityRevealAudit', 'ModerationEvent') OR target_kind = 'Audit'"
    drop_table :river_whisper_audits
    remove_column :river_whisper_bans, :reason
  end

  # Restore the previous schema for an application rollback, not removed history.
  def down
    add_column :river_whisper_bans, :reason, :string, null: false, default: '树洞发布权限已限制'
    create_table :river_whisper_audits do |t|
      t.bigint :user_id, null: false
      t.string :action, null: false
      t.string :target_kind
      t.bigint :target_id
      t.string :reason, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
  end
end
