# frozen_string_literal: true
module DiscourseWhisper
  class Post < Record; self.table_name='river_whisper_posts'; end
  class Alias < Record; self.table_name='river_whisper_aliases'; end
  class Ban < Record; self.table_name='river_whisper_bans'; end
  module Service
    ADMIN_OPERATIONS=%w[moderate reveal ban resolve_report dismiss_reports].freeze
    def self.targets = {'Post'=>Post,'Comment'=>Comment}
    def self.authorize_operation!(user,operation)
      Access.check!(user,admin:true) if ADMIN_OPERATIONS.include?(operation)
      if Ban.exists?(user_id:user.id) && !Access.admin?(user) && !%w[delete_own mark_read].include?(operation)
        raise Error,'你当前被限制在树洞发布内容'
      end
    end
    def self.post_for(item) = item.is_a?(Post) ? item : Post.find(item.target_id)
    def self.can_view?(post,user)
      post.status=='visible' || Access.admin?(user) || (post.status=='hidden' && post.user_id==user.id)
    end
    def self.visible_target!(item,user)
      post=post_for(item)
      raise Discourse::InvalidAccess unless item.status=='visible' && post.status=='visible'
      raise Discourse::InvalidAccess if item.is_a?(Comment) && item.target_kind!='Post'
    end
    def self.alias_name(post,uid)
      return '洞主' if post.user_id==uid
      a=Alias.find_by(post_id:post.id,user_id:uid)
      return '匿名' unless a
      n=a.ordinal;name=''
      loop do
        name=(65+n%26).chr+name;n=n/26-1;break if n<0
      end
      "匿名 #{name}"
    end
    def self.notification_text(kind)
      {'COMMENT_REPLY'=>'你的树洞或回复收到了一条新回复','POST_LIKE'=>'你的树洞收到了赞','POST_REPORT'=>'你的树洞有新的举报','COMMENT_REPORT'=>'你的树洞回复有新的举报','MODERATION'=>'你的树洞内容有新的管理处理','REPORT_RESOLVED'=>'你的树洞举报已处理','BAN'=>'你的树洞发布权限已更新'}[kind] || '树洞有新的动态'
    end
    def self.path(post,comment=nil)
      "/whisper?view=post&id=#{post.id}#{comment ? "&reply=#{comment.id}#whisper-reply-#{comment.id}" : ''}"
    end
    def self.paginate(scope,query,size=20)
      total=scope.count;pages=[(total.to_f/size).ceil,1].max;page=[[query['page'].to_i,1].max,pages].min
      [scope.offset((page-1)*size).limit(size),{page:page,pages:pages,total:total,next:page<pages ? page+1 : nil,previous:page>1 ? page-1 : nil}]
    end
    def self.summary(post,user)
      reaction=Reaction.where(target_kind:'Post',target_id:post.id)
      {id:post.id,public_code:post.public_code,title:post.title.presence || "树洞 ##{post.public_code}",excerpt:post.body.truncate(180),created_at:post.created_at,activity_at:post.last_comment_at || post.created_at,status:post.status,mine:post.user_id==user.id,url:path(post),
       replies:Comment.where(target_kind:'Post',target_id:post.id,status:'visible').count,likes:reaction.where(value:1).count,dislikes:reaction.where(value:-1).count,images:Shared.media_urls(post.media_ids.first(2)),image_count:post.media_ids.length,missing_media_count:post.missing_media_count}
    end
    def self.entry(item,post,user,floors={})
      kind=item.is_a?(Post) ? 'Post' : 'Comment';masked=item.status!='visible' && !Access.admin?(user) && !(kind=='Post' && item.status=='hidden' && item.user_id==user.id)
      interactive=!SiteSetting.whisper_read_only && (!Ban.exists?(user_id:user.id) || Access.admin?(user)) && item.status=='visible' && post.status=='visible'
      reactions=Reaction.where(target_kind:kind,target_id:item.id)
      label=alias_name(post,item.user_id)
      out={id:item.id,kind:kind,alias:label,initial:label=='洞主' ? '洞' : label.delete_prefix('匿名 '),mine:item.user_id==user.id,body:masked ? (item.status=='deleted' ? '这条回复已删除' : '这条回复已隐藏') : item.body,
        masked:masked,status:item.status,created_at:item.created_at,floor:kind=='Post' ? 1 : floors[item.id],can_reply:interactive,can_interact:interactive,can_manage:Access.admin?(user) && !SiteSetting.whisper_read_only,
        can_delete:item.user_id==user.id && item.status!='deleted' && !SiteSetting.whisper_read_only,likes:masked ? 0 : reactions.where(value:1).count,dislikes:masked ? 0 : reactions.where(value:-1).count,reaction:reactions.find_by(user_id:user.id)&.value,
        reported:Report.exists?(user_id:user.id,target_kind:kind,target_id:item.id,handled_at:nil),images:masked ? [] : Shared.media_urls(item.media_ids),url:path(post,kind=='Comment' ? item : nil)}
      if kind=='Comment' && item.parent_id && (parent=Comment.find_by(id:item.parent_id,target_kind:'Post',target_id:post.id))
        out[:parent]={id:parent.id,alias:alias_name(post,parent.user_id),floor:floors[parent.id],excerpt:parent.status=='visible' ? parent.body.truncate(100) : '该回复已隐藏或删除',url:path(post,parent)}
      end
      out
    end
    def self.state(user,query)
      Access.check!(user)
      view=query['view'].presence || 'feed'
      raise Discourse::NotFound unless %w[feed new post mine notifications admin].include?(view)
      ban=Ban.find_by(user_id:user.id)
      out={title:'树洞',view:view,readonly:SiteSetting.whisper_read_only,admin:Access.admin?(user),banned:ban.present? && !Access.admin?(user),ban_reason:ban&.reason,
        tabs:[{id:'feed',label:'树洞广场'},{id:'mine',label:'我的参与'},{id:'notifications',label:'消息'}],unread:Inbox.where(user_id:user.id,read:false).count,rows:[],forms:[]}
      out[:tabs]<<{id:'admin',label:'管理'} if Access.admin?(user)
      case view
      when 'feed','mine'
        if view=='mine' && query['part']=='replies'
          out[:part]='replies'
          scope,paging=paginate(Comment.where(user_id:user.id,status:'visible').order(created_at: :desc,id: :desc),query)
          out[:rows]=scope.map do |c|
            post=Post.find(c.target_id);available=can_view?(post,user)
            {id:c.id,comment:true,title:available ? (post.title.presence || "树洞 ##{post.public_code}") : '树洞已不可见',excerpt:c.body,created_at:c.created_at,activity_at:c.created_at,status:c.status,url:available ? path(post,c) : nil,can_delete:!SiteSetting.whisper_read_only}
          end
        else
          q=query['q'].to_s.strip
          scope=if view=='mine'
            Post.where(user_id:user.id,status:%w[visible hidden])
          elsif q.present?
            Post.where(status:'visible').where('title ILIKE :q OR body ILIKE :q OR public_code ILIKE :q',q:"%#{ActiveRecord::Base.sanitize_sql_like(q)}%")
          else
            Post.where('status = ? OR (status = ? AND user_id = ?)','visible','hidden',user.id)
          end
          sort=query['sort']=='active' && q.blank? && view=='feed' ? 'active' : 'new'
          scope=sort=='active' ? scope.order(Arel.sql('last_comment_at DESC NULLS LAST, created_at DESC, id DESC')) : scope.order(created_at: :desc,id: :desc)
          scope,paging=paginate(scope,query)
          out.merge!(q:q,sort:sort,part:'posts',rows:scope.map { |post| summary(post,user) })
        end
        out[:pagination]=paging
      when 'new'
        if !out[:readonly] && !out[:banned]
          out[:forms]=[Ui.form('发布树洞','post',[Ui.field('title','标题（可选）',maxlength:80),Ui.field('body','想说的话',type:'textarea',required:true,maxlength:4000),Ui.field('images','配图',type:'upload')],button:'匿名发布')]
        end
      when 'post'
        post=query['code'].present? ? Post.find_by!(public_code:query['code']) : Post.find(Shared.id(query['id']))
        raise Discourse::InvalidAccess unless can_view?(post,user)
        comments=Comment.where(target_kind:'Post',target_id:post.id).order(:created_at,:id)
        ids=comments.pluck(:id);floors=ids.each_with_index.to_h { |id,i| [id,i+2] }
        selected=query.dup
        if query['reply'].present? && (index=ids.index(query['reply'].to_i))
          selected['page']=index/50+1
        end
        page,paging=paginate(comments,selected,50)
        # A hidden post remains visible only to its owner/staff; hidden reply bodies remain staff-only.
        out.merge!(post:summary(post,user).merge(entry(post,post,user)),replies:page.map { |c| entry(c,post,user,floors) },pagination:paging,
          audits:Audit.where(target_kind:'Post',target_id:post.id,action:'reveal_identity').order(:created_at,:id).map { |a| {id:a.id,moderator:Shared.user_name(a.user_id),reason:a.reason,created_at:a.created_at} })
      when 'notifications'
        scope,paging=paginate(Inbox.where(user_id:user.id).order(created_at: :desc,id: :desc),query)
        out[:rows]=scope.map do |n|
          post=Post.find_by(id:n.post_id);available=post && can_view?(post,user)
          comment=Comment.find_by(id:n.comment_id,target_id:post&.id)
          {id:n.id,title:notification_text(n.kind),message:n.message.presence || (n.kind=='COMMENT_REPLY' && available && comment&.status=='visible' ? comment.body.truncate(80) : nil),read:n.read,historical:n.historical,created_at:n.created_at,url:available ? path(post,comment) : nil,post_label:available ? (post.title.presence || "树洞 ##{post.public_code}") : '树洞已不可见'}
        end
        out[:pagination]=paging
      when 'admin'
        Access.check!(user,admin:true)
        admin_state(out,user,query)
      end
      out
    end
    def self.admin_state(out,user,query)
      part=%w[posts reports audits bans].include?(query['part']) ? query['part'] : 'posts';out[:part]=part
      case part
      when 'posts'
        status=%w[visible hidden deleted].include?(query['status']) ? query['status'] : 'all';scope=Post.all;scope=scope.where(status:status) unless status=='all'
        scope,paging=paginate(scope.order(created_at: :desc,id: :desc),query,30)
        out.merge!(status:status,rows:scope.map { |p| summary(p,user) },pagination:paging)
      when 'reports'
        scope,paging=paginate(Report.where(handled_at:nil).order(created_at: :desc,id: :desc),query,30)
        out[:rows]=scope.map do |r|
          item=targets.fetch(r.target_kind).find_by(id:r.target_id);post=item && post_for(item)
          {id:r.id,kind:r.target_kind,target_id:r.target_id,reason:r.reason,created_at:r.created_at,body:item&.body,status:item&.status,url:post ? path(post,item.is_a?(Comment) ? item : nil) : nil,public_code:post&.public_code}
        end
        out[:pagination]=paging
      when 'audits'
        scope,paging=paginate(Audit.order(created_at: :desc,id: :desc),query,30)
        out[:rows]=scope.map { |a| {id:a.id,moderator:Shared.user_name(a.user_id),action:a.action,reason:a.reason,created_at:a.created_at} };out[:pagination]=paging
      when 'bans'
        out[:rows]=Ban.order(id: :desc).map { |b| {id:b.id,username:Shared.user_name(b.user_id),reason:b.reason,created_at:b.created_at} }
        out[:forms]=[Ui.form('树洞发言限制','ban',[Ui.field('username','论坛用户名',required:true),Ui.field('banned','限制发言',true,type:'checkbox'),Ui.field('reason','处理理由',required:true,maxlength:240)],button:'保存限制')] unless out[:readonly]
      end
    end
    def self.call(user,operation,data)
      Access.check!(user);Access.writable!;authorize_operation!(user,operation)
      case operation
      when 'post'
        code=nil
        12.times do
          code=Array.new(5) { 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[SecureRandom.random_number('ABCDEFGHJKLMNPQRSTUVWXYZ23456789'.length)] }.join
          break unless Post.exists?(public_code:code)
        end
        raise Error,'编号生成失败，请重试' if Post.exists?(public_code:code)
        post=Post.create!(user_id:user.id,public_code:code,title:Shared.text(data['title'],80,required:false).presence,body:Shared.text(data['body'],4000),media_ids:Shared.media_ids(user,data['media_ids']))
        {query:{view:'post',id:post.id}}
      when 'reply'
        post=Post.lock.find(Shared.id(data['id']));visible_target!(post,user)
        parent=data['parent_id'].present? ? Comment.find(Shared.id(data['parent_id'])) : nil
        raise Error,'回复不属于此树洞' if parent && (parent.target_kind!='Post' || parent.target_id!=post.id || parent.status!='visible')
        unless post.user_id==user.id || Alias.exists?(post_id:post.id,user_id:user.id)
          Alias.create!(post_id:post.id,user_id:user.id,ordinal:(Alias.where(post_id:post.id).maximum(:ordinal) || -1)+1)
        end
        comment=Comment.create!(user_id:user.id,target_kind:'Post',target_id:post.id,parent_id:parent&.id,body:Shared.text(data['body'],1200),anonymous:true)
        post.update!(last_comment_at:comment.created_at)
        ([post.user_id,parent&.user_id].compact.uniq-[user.id]).each { |id| Shared.notify(id,'COMMENT_REPLY',post:post,comment:comment,key:"reply:#{comment.id}:#{id}") }
        {query:{view:'post',id:post.id,reply:comment.id},message:'回复已发布'}
      when 'react','report','delete_own','moderate'
        klass=targets[data['kind']];raise Error,'无效内容类型' unless klass
        item=klass.lock.find(Shared.id(data['id']));post=post_for(item)
        if operation=='delete_own'
          raise Discourse::InvalidAccess unless item.user_id==user.id
          item.update!(status:'deleted') unless item.status=='deleted'
          return item.is_a?(Post) ? {query:{view:'mine'},message:'树洞已删除'} : {message:'回复已删除'}
        end
        if operation=='moderate'
          status=data['status'];raise Error,'无效状态' unless %w[visible hidden deleted].include?(status)
          Shared.audit(user,status,item,data['reason']);item.update!(status:status)
          Shared.notify(item.user_id,'MODERATION',post:post,key:"moderate:#{item.class.name}:#{item.id}:#{item.updated_at.to_f}")
          return {message:'管理处理已保存'}
        end
        visible_target!(item,user)
        operation=='react' ? react(user,item,post,data['value']) : report(user,item,post,data['reason'])
      when 'reveal'
        post=Post.find(Shared.id(data['id']));Shared.audit(user,'reveal_identity',post,data['reason'],{'revealed_user_id'=>post.user_id})
        {message:"已记录公开审计。洞主：#{Shared.user_name(post.user_id)}",identity_user_id:post.user_id}
      when 'ban'
        target=User.find_by!(username_lower:data['username'].to_s.strip.downcase);reason=Shared.text(data['reason'],240)
        Shared.bool(data['banned']) ? Ban.find_or_initialize_by(user_id:target.id).update!(reason:reason) : Ban.where(user_id:target.id).delete_all
        Shared.audit(user,'posting_restriction',target,reason)
        Shared.notify(target.id,'BAN',key:"ban:#{target.id}:#{SecureRandom.uuid}");{message:'发言限制已更新'}
      when 'resolve_report','dismiss_reports'
        scope=operation=='resolve_report' ? Report.where(id:Shared.id(data['id']),handled_at:nil) : Report.where(target_kind:data['kind'],target_id:Shared.id(data['id']),handled_at:nil)
        scope.lock.each do |r|
          r.update!(handled_at:Time.current);Shared.audit(user,'resolve_report',r,'举报已处理')
          Shared.notify(r.user_id,'REPORT_RESOLVED',key:"report-resolved:#{r.id}")
        end
        {message:'举报已处理'}
      when 'mark_read'
        scope=Inbox.where(user_id:user.id,read:false);scope=scope.where(id:Shared.id(data['id'])) if data['id'].present?
        keys=scope.pluck(:event_key).compact;scope.update_all(read:true)
        ids=Event.where(user_id:user.id,key:keys).pluck(:notification_id).compact
        if ids.any?
          Notification.read(user,ids);user.reload.publish_notifications_state
        end
        {}
      else raise Error,'未知操作'
      end
    end
    def self.react(user,item,post,value)
      value=Integer(value.to_s,10) rescue nil;raise Error,'无效反馈' unless [-1,0,1].include?(value)
      scope=Reaction.where(user_id:user.id,target_kind:item.class.name.demodulize,target_id:item.id)
      previous=scope.first&.value
      value==0 ? scope.delete_all : scope.first_or_initialize.update!(value:value)
      if item.is_a?(Post) && value==1 && previous!=1 && item.user_id!=user.id
        count=Reaction.where(target_kind:'Post',target_id:item.id,value:1).count
        inbox=Inbox.where(user_id:item.user_id,post_id:item.id,kind:'POST_LIKE',read:false,historical:false).first
        if inbox
          inbox.update!(message:"已收到 #{count} 个赞",created_at:Time.current)
        else
          Shared.notify(item.user_id,'POST_LIKE',post:post,message:"已收到 #{count} 个赞",key:"like:#{post.id}:#{SecureRandom.uuid}")
        end
      end
      {}
    end
    def self.report(user,item,post,reason)
      reason=Shared.text(reason,240)
      scope=Report.where(user_id:user.id,target_kind:item.class.name.demodulize,target_id:item.id)
      r=scope.first
      if !r || r.handled_at
        r ? r.update!(reason:reason,handled_at:nil,created_at:Time.current) : r=scope.create!(reason:reason)
        if item.user_id!=user.id
          Shared.notify(item.user_id,item.is_a?(Post) ? 'POST_REPORT' : 'COMMENT_REPORT',post:post,comment:item.is_a?(Comment) ? item : nil,message:reason,key:"report:#{r.id}:#{r.created_at.to_f}")
        end
      end
      {message:'举报已提交'}
    end
    def self.media_allowed?(user,item)
      return false unless Access.member?(user)
      return true if item.user_id==user.id || Access.admin?(user)
      Post.where(status:'visible').where('media_ids @> ?', [item.id].to_json).exists?
    end
    def self.legacy_query(path,params={})
      if path.start_with?('post/')
        id=Legacy.find_by(source:'Post',legacy_id:path.split('/',2).last)&.target_id
        return id ? {view:'post',id:id} : {view:'feed'}
      end
      return {view:'mine'} if path=='me'
      return {view:'notifications'} if path=='notifications'
      return {view:'admin',part:params['tab']=='reports' ? 'reports' : 'posts'} if path=='admin'
      {view:'feed'}.merge(params.to_h.slice('q','sort','page'))
    end
  end
end
