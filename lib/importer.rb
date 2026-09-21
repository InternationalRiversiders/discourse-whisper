# frozen_string_literal: true
require 'digest'
module DiscourseWhisper
  class Importer
    def initialize(payload, directory: nil, allow_missing_media: false)
      @payload=payload;@tables=payload.fetch('tables');@directory=directory;@media_cache={};@allow_missing_media=allow_missing_media
      raise Error,'导出文件格式或项目不符' unless payload['format']=='riverside-community-v1' && payload['project']=='whisper'
    end
    def rows(name) = @tables[name] || []
    def ref(name,id,optional:false)
      return nil if id.nil? && optional
      value=Legacy.find_by(source:name,legacy_id:id.to_s)&.target_id
      raise Error,"缺少关联：#{name}/#{id}" unless value || optional
      value
    end
    def user(id,optional:false)
      return nil if id.nil? && optional
      uid=Integer(id.to_s,10) rescue nil
      raise Error,"论坛用户不存在：#{id}" unless uid && User.exists?(uid)
      uid
    end
    def local_user(id,optional:false)
      return nil if id.nil? && optional
      row=rows('User').find { |u| u['id'].to_s==id.to_s }
      raise Error,"本地用户不存在：#{id}" unless row
      user(row.fetch('externalUserId'))
    end
    def stamp(row)
      %w[createdAt updatedAt].each_with_object({}) do |key,h|
        h[key=='createdAt' ? :created_at : :updated_at]=Time.iso8601(row[key]) if row[key].present?
      end
    end
    def put(source,row,klass,attrs)
      item=klass.create!(stamp(row).merge(attrs))
      Legacy.find_by!(source:source,legacy_id:row.fetch('id').to_s).update!(target_kind:klass.name.demodulize,target_id:item.id)
      item
    end
    def status(row)
      value=row['status'].to_s.downcase
      return value if %w[visible hidden deleted].include?(value)
      row['hidden'] || row['hiddenAt'] ? 'hidden' : 'visible'
    end
    def images(values,uid)
      values=JSON.parse(values) if values.is_a?(String)
      Array(values).map do |name|
        next @media_cache[name] if @media_cache.key?(name)
        entry=Array(@payload['media']).find { |m| m['name']==name }
        raise Error,"缺少图片文件：#{name}" unless entry && @directory
        if entry['missing']
          raise Error,'旧版有缺失图片；核对清单后才可显式允许缺图导入' unless @allow_missing_media
          next nil
        end
        root=File.realpath(@directory);path=File.realpath(File.join(root,entry.fetch('file')))
        raise Error,'图片路径越界' unless path.start_with?(root+'/')
        raw=File.binread(path);raise Error,'图片校验和不符' unless Digest::SHA256.hexdigest(raw)==entry['sha256']
        bytes=Shared.image(raw)
        raise Error,'压缩后图片超过 1MB' if bytes.bytesize>1.megabyte
        media=Media.create!(user_id:uid,token:SecureRandom.hex(24),bytes:bytes,size:bytes.bytesize)
        @media_cache[name]=media.id
      end.compact
    end
    def run(sha:,apply:false,expected_sha:nil)
      raise Error,'正式导入需要匹配的 SHA256' if apply && sha!=expected_sha
      raise Error,'正式导入前请关闭插件' if apply && SiteSetting.whisper_enabled
      result=nil
      Record.transaction do
        Shared.lock('legacy-import')
        existing=Legacy.find_by(source:'__manifest',legacy_id:sha)
        if existing
          result={already_imported:true,sha256:sha,counts:existing.data['counts']};next
        end
        tables=ActiveRecord::Base.connection.tables.grep(/\Ariver_whisper_/)
        occupied=tables.any? { |table| ActiveRecord::Base.connection.select_value("SELECT EXISTS(SELECT 1 FROM #{ActiveRecord::Base.connection.quote_table_name(table)})") }
        raise Error,'目标插件已有业务数据，请使用空的隔离目标演练' if occupied
        @tables.each do |source,records|
          raise Error,'记录列表无效' unless records.is_a?(Array)
          records.each { |row| Legacy.create!(source:source,legacy_id:row.fetch('id',row['key']).to_s,data:row) }
        end
        import_domain
        counts=tables.to_h { |table| [table,ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{ActiveRecord::Base.connection.quote_table_name(table)}").to_i] }
        # No old event is delivered by importing; historical notifications are available in the private inbox.
        result={sha256:sha,apply:apply,source_counts:@tables.transform_values(&:size),counts:counts,missing_media:Array(@payload['media']).count { |m| m['missing'] }}
        Legacy.create!(source:'__manifest',legacy_id:sha,data:result)
        ActiveRecord::Base.connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
        raise ActiveRecord::Rollback unless apply
      end
      result
    end
    def import_reaction(source,row,target_source,target_id,value)
      target=Legacy.find_by!(source:target_source,legacy_id:target_id.to_s)
      uid=row.key?('externalUserId') ? user(row['externalUserId']) : local_user(row['userId'])
      item=Reaction.find_or_initialize_by(user_id:uid,target_kind:target.target_kind,target_id:target.target_id)
      raise Error,'同一用户对同一内容有冲突的赞踩记录' if item.persisted? && item.value!=value
      item.update!(stamp(row).merge(value:value))
      Legacy.find_by!(source:source,legacy_id:row['id'].to_s).update!(target_kind:'Reaction',target_id:item.id)
    end
  end
end

module DiscourseWhisper
  class Importer
    def import_domain
      rows('User').each { |u| Ban.create!(user_id:user(u['externalUserId']),reason:u['banReason'].presence || '迁移前的树洞发布限制',created_at:Time.iso8601(u['bannedAt']),updated_at:Time.iso8601(u['bannedAt'])) if u['bannedAt'] }
      rows('Post').each { |r| uid=local_user(r['authorId']);put('Post',r,Post,{user_id:uid,public_code:r['publicCode'],title:r['title'],body:r['body'],status:status(r),media_ids:images(r['imageUrls'],uid),last_comment_at:r['lastCommentAt'],missing_media_count:Array(r['imageUrls']).count { |name| Array(@payload['media']).any? { |m| m['name']==name && m['missing'] } }}) }
      pending=rows('Comment').sort_by { |r| [r['createdAt'].to_s,r['id'].to_s] }
      until pending.empty?
        progress=false
        pending.delete_if do |r|
          next false if r['parentId'] && !Legacy.find_by(source:'Comment',legacy_id:r['parentId'].to_s)&.target_id
          post=Post.find(ref('Post',r['postId']));uid=local_user(r['authorId'])
          # Assign aliases to visible authors first, as the old public view did.
          put('Comment',r,Comment,{user_id:uid,target_kind:'Post',target_id:post.id,parent_id:r['parentId'] ? ref('Comment',r['parentId']) : nil,body:r['body'],anonymous:true,status:status(r)})
          progress=true;true
        end
        raise Error,'树洞回复关系有缺失或循环' unless progress
      end
      Post.find_each do |post|
        comments=Comment.where(target_kind:'Post',target_id:post.id).order(:created_at,:id).to_a
        (comments.select { |c| c.status=='visible' }+comments.reject { |c| c.status=='visible' }).each do |c|
          next if c.user_id==post.user_id || Alias.exists?(post_id:post.id,user_id:c.user_id)
          Alias.create!(post_id:post.id,user_id:c.user_id,ordinal:Alias.where(post_id:post.id).count)
        end
      end
      rows('Reaction').each { |r| import_reaction('Reaction',r,r['targetType']=='COMMENT' ? 'Comment' : 'Post',r['commentId'] || r['postId'],r['type']=='DISLIKE' ? -1 : 1) }
      rows('Report').each { |r| kind=r['targetType']=='COMMENT' ? 'Comment' : 'Post';put('Report',r,Report,{user_id:local_user(r['reporterId']),target_kind:kind,target_id:ref(kind,r['commentId'] || r['postId']),reason:r['reason']}) }
      rows('IdentityRevealAudit').each { |r| put('IdentityRevealAudit',r,Audit,{user_id:local_user(r['moderatorId']),action:'reveal_identity',target_kind:'Post',target_id:ref('Post',r['postId']),reason:r['reason'],details:{revealed_user_id:local_user(r['revealedUserId'])}}) }
      rows('Notification').each { |r| put('Notification',r,Inbox,{user_id:local_user(r['userId']),post_id:ref('Post',r['postId']),comment_id:r['commentId'] ? ref('Comment',r['commentId']) : nil,kind:r['type'],message:r['message'],read:!!r['read'],historical:true}) }
      rows('ModerationEvent').each { |r| kind=r['commentId'] ? 'Comment' : 'Post';put('ModerationEvent',r,Audit,{user_id:local_user(r['moderatorId']),action:r['action'],target_kind:kind,target_id:ref(kind,r['commentId'] || r['postId']),reason:r['reason'].presence || '迁移前的管理操作'}) }
    end
  end
end
