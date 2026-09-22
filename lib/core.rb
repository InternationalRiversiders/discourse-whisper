# frozen_string_literal: true
require 'digest'
require 'vips'
module DiscourseWhisper
  class Error < StandardError; end
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end
  %w[Command Event Audit Legacy Media Reaction Report Comment Inbox].each do |name|
    klass = Class.new(Record)
    klass.table_name = name == 'Media' ? 'river_whisper_media' : "river_whisper_#{name.underscore.pluralize}"
    const_set(name, klass)
  end
  module Access
    def self.admin?(user)
      user && user.active? && !user.suspended? && (user.admin? || user.in_any_groups?(SiteSetting.whisper_admin_groups.split('|').map(&:to_i)))
    end
    def self.member?(user)
      return admin?(user) if SiteSetting.whisper_admin_only
      user && user.active? && !user.suspended? && (admin?(user) || user.in_any_groups?(SiteSetting.whisper_allowed_groups.split('|').map(&:to_i)))
    end
    def self.check!(user, admin: false)
      raise Discourse::InvalidAccess unless SiteSetting.whisper_enabled && (admin ? admin?(user) : member?(user))
    end
    def self.writable!
      raise Error, '当前为只读预览，暂不接受修改' if SiteSetting.whisper_read_only
    end
  end
  module Shared
    def self.text(value, max = 4000, required: true)
      text = value.to_s.strip
      raise Error, '请填写必填内容' if required && text.empty?
      raise Error, "内容超过 #{max} 字限制" if text.length > max
      text
    end
    def self.id(value)
      number = Integer(value.to_s, 10) rescue nil
      raise Error, '无效的编号' unless number && number > 0
      number
    end
    def self.bool(value) = value == true || %w[true 1].include?(value.to_s)
    def self.lock(key)
      number = Digest::SHA256.digest("river_whisper:#{key}").unpack1('q>')
      Record.connection.execute("SELECT pg_advisory_xact_lock(#{number})")
    end
    def self.canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |key| [key, canonical(value[key])] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end
    def self.command(user, operation, data, key)
      Access.check!(user); Access.writable!
      Service.authorize_operation!(user, operation)
      raise Error, '请求编号缺失' unless key.to_s.match?(/\A[\w-]{8,100}\z/)
      fingerprint = Digest::SHA256.hexdigest([operation, canonical(data)].to_json)
      Record.transaction do
        lock("user:#{user.id}"); lock("command:#{user.id}:#{key}")
        existing = Command.find_by(user_id: user.id, key: key)
        if existing
          raise Error, '请求编号已用于其他操作' unless existing.fingerprint == fingerprint
          next existing.result
        end
        result = yield || {}
        Command.create!(user_id: user.id, key: key, fingerprint: fingerprint, result: result)
        result
      end
    end
    def self.audit(actor, action, item, reason, details = {})
      Audit.create!(user_id: actor.id, action: action, target_kind: item.class.name.demodulize, target_id: item.id, reason: text(reason, 240), details: details)
    end
    # Public forum fields only; callers enforce each feature's anonymity rules.
    def self.forum_user(id)
      user = id.is_a?(User) ? id : User.find_by(id: id)
      user && { id: user.id, username: user.username, avatar_template: user.avatar_template }
    end
    def self.user_name(id) = User.find_by(id: id)&.username || '已注销用户'
    def self.notify(user_id, kind, post: nil, comment: nil, message: nil, key:)
      return unless user_id && User.exists?(user_id)
      inbox = Inbox.create_or_find_by!(event_key: key) do |i|
        i.user_id = user_id; i.kind = kind; i.post_id = post&.id; i.comment_id = comment&.id; i.message = message
      end
      path = post ? "/whisper?view=post&id=#{post.id}#{comment ? "&reply=#{comment.id}" : ''}" : '/whisper?view=notifications'
      Event.create_or_find_by!(key: key) do |e|
        e.user_id = user_id; e.text = Service.notification_text(kind); e.path = path
      end
      inbox
    end
    def self.deliver
      return unless SiteSetting.whisper_enabled && !SiteSetting.whisper_read_only
      Event.where(notification_id: nil).order(:id).limit(100).each do |event|
        event.with_lock do
          next if event.notification_id || !Access.member?(User.find_by(id: event.user_id))
          n = Notification.create!(user_id: event.user_id, notification_type: Notification.types[:custom], skip_send_email: true,
            data: {river_app: 'whisper', river_text: event.text, river_path: event.path, river_icon: 'leaf', message: 'whisper', display_username: '', topic_title: event.text}.to_json)
          event.update!(notification_id: n.id)
        end
      rescue StandardError => e
        Rails.logger.warn("whisper notification #{event.id}: #{e.class}")
      end
    end
    def self.image(bytes)
      signature = bytes.byteslice(0,12)
      valid = signature&.start_with?("\xFF\xD8\xFF".b, "\x89PNG\r\n\x1A\n".b, 'GIF87a'.b, 'GIF89a'.b) || (signature&.start_with?('RIFF') && signature.byteslice(8,4)=='WEBP')
      raise Error, '只支持 JPEG、PNG、GIF 或 WebP 图片' unless valid
      image=Vips::Image.new_from_buffer(bytes,'',access: :sequential)
      raise Error,'图片尺寸过大' if image.width*image.height>30_000_000
      image=image.autorot
      image=image.flatten(background: [255,255,255]) if image.has_alpha?
      # Match the old uploader's bounded compression attempts without preserving metadata.
      image=image.copy_memory
      [[1200,78],[1200,55],[800,70],[800,50]].each do |width,quality|
        ratio=[width.to_f/image.width,width.to_f/image.height,1].min
        candidate=(ratio<1 ? image.resize(ratio) : image).jpegsave_buffer(Q:quality,strip:true)
        return candidate if candidate.bytesize<=1.megabyte
      end
      raise Error,'压缩后的图片仍然过大'
    end
    def self.media_ids(user, values)
      ids=Array(values).map { |v| id(v) }.uniq
      raise Error, '最多上传 9 张图片' if ids.size>9
      raise Error, '图片不属于你或已不存在' unless Media.where(id:ids,user_id:user.id).count==ids.size
      ids
    end
    def self.media_urls(ids) = Array(ids).map { |id| "/whisper/media/#{id}" }
  end
  class MainController < ::ApplicationController
    requires_plugin 'discourse-whisper'
    skip_before_action :check_xhr, only: [:index,:media,:legacy,:export]
    before_action :enabled!
    rescue_from Error, ArgumentError do |error|
      render_json_dump({errors:[error.message]},status:422)
    end
    def index
      Access.check!(current_user)
      response.headers['Cache-Control']='private, no-store'
      render 'default/empty'
    end
    def state
      Access.check!(current_user)
      response.headers['Cache-Control']='private, no-store'
      render_json_dump(Service.state(current_user,params.to_unsafe_h))
    end
    def mutate
      Access.check!(current_user);Access.writable!
      RateLimiter.new(current_user,'whisper-write',40,1.minute).performed!
      data=params.fetch(:data,ActionController::Parameters.new).permit!.to_h
      result=Shared.command(current_user,params.require(:operation).to_s,data,params.require(:request_id)) { Service.call(current_user,params[:operation].to_s,data) }
      Shared.deliver
      response.headers['Cache-Control']='private, no-store'
      render_json_dump(result)
    end
    def upload
      Access.check!(current_user);Access.writable!;Service.authorize_operation!(current_user,'post')
      RateLimiter.new(current_user,'whisper-upload',20,1.hour).performed!
      file=params.require(:file)
      raise Error,'图片最大 10MB' unless file.respond_to?(:tempfile) && file.size.between?(1,10.megabytes)
      bytes=Shared.image(File.binread(file.tempfile.path))
      item=Record.transaction do
        Shared.lock("media:#{current_user.id}")
        raise Error,'图片空间已达 50MB' if Media.where(user_id:current_user.id).sum(:size)+bytes.bytesize>50.megabytes
        Media.create!(user_id:current_user.id,bytes:bytes,size:bytes.bytesize,token:SecureRandom.hex(24))
      end
      render_json_dump({id:item.id,url:"/whisper/media/#{item.id}"})
    rescue Vips::Error
      render_json_dump({errors:['无法处理此图片']},status:422)
    end
    def media
      Access.check!(current_user)
      item=Media.find(params[:id])
      raise Discourse::InvalidAccess unless Service.media_allowed?(current_user,item)
      response.headers['Cache-Control']='private, no-store'
      response.headers['X-Content-Type-Options']='nosniff'
      send_data(item.bytes,type:'image/jpeg',disposition:'inline')
    end
    def legacy
      redirect_to('/whisper?'+Service.legacy_query(params[:path].to_s.delete_suffix('/'),params.permit(:q,:sort,:page,:tab).to_h).to_query,allow_other_host:false)
    end
    def export
      Access.check!(current_user)
      response.headers['Cache-Control']='private, no-store'
      send_data(JSON.pretty_generate(UserLifecycle.export(current_user.id)),type:'application/json',filename:'my-whisper-data.json')
    end
    private
    def enabled!
      raise Discourse::NotFound unless SiteSetting.whisper_enabled
    end
  end
  module Ui
    def self.field(name,label,value=nil,type:'text',options:nil,required:false,maxlength:nil)
      {name:name,label:label,value:value,type:type,options:options&.map { |v| v.is_a?(Array) ? {value:v[0],label:v[1]} : {value:v,label:v} },required:required,maxlength:maxlength}
    end
    def self.form(title,operation,fields,data={},button:'保存',danger:false)
      {title:title,operation:operation,fields:fields,data:data,button:button,danger:danger}
    end
  end
end
module ::Jobs
  class DiscourseWhisperTick < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      return unless SiteSetting.whisper_enabled && !SiteSetting.whisper_read_only
      DistributedMutex.synchronize('whisper-tick') { DiscourseWhisper::Shared.deliver }
    end
  end
end
