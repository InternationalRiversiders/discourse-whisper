# frozen_string_literal: true
abort 'Disposable test database only' unless ENV['RIVER_DISPOSABLE']=='1' && GlobalSetting.db_name=='river_community_test'
require 'minitest/autorun'
require 'active_support/testing/time_helpers'
class WhisperTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  A=DiscourseWhisper
  def setup
    tables=A::Record.connection.tables.grep(/\Ariver_whisper_/)
    A::Record.connection.execute('TRUNCATE '+tables.map { |t| A::Record.connection.quote_table_name(t) }.join(',')+' RESTART IDENTITY CASCADE')
    @group=Group.find_or_create_by!(name:'whisper_test_members')
    @admin=make_user('whisper_admin',true);@alice=make_user('whisper_alice');@bob=make_user('whisper_bob');@carol=make_user('whisper_carol');@outsider=make_user('whisper_outsider')
    [@alice,@bob,@carol].each { |u| @group.add(u);u.reload }
    SiteSetting.whisper_enabled=true;SiteSetting.whisper_read_only=false;SiteSetting.whisper_admin_only=false
    SiteSetting.whisper_allowed_groups=@group.id.to_s;SiteSetting.whisper_admin_groups=''
  end
  def make_user(name,admin=false)
    user=User.find_by(username:name) || User.create!(username:name,email:"#{name}@example.com",password:SecureRandom.hex(30),active:true,approved:true,admin:admin)
    user.update!(admin:admin,active:true,suspended_till:nil);user
  end
  def call(user,op,data={},key:SecureRandom.uuid)
    A::Shared.command(user,op,data.deep_stringify_keys,key) { A::Service.call(user,op,data.deep_stringify_keys) }
  end
  def post(user=@alice,body:'一段匿名文字')
    A::Post.find(call(user,'post',{body:body})[:query][:id])
  end
  def reply(p,user=@bob,parent:nil,body:'认真回复')
    A::Comment.find(call(user,'reply',{id:p.id,parent_id:parent&.id,body:body})[:query][:reply])
  end
  def state(user=@alice,**query) = A::Service.state(user,query.deep_stringify_keys)
  def test_permission_readonly_and_admin_preview_gates
    assert_raises(Discourse::InvalidAccess) { state(@outsider) }
    assert_raises(Discourse::InvalidAccess) { call(@outsider,'post',{body:'x'}) }
    p=post
    SiteSetting.whisper_read_only=true
    assert state[:readonly]
    assert_empty state(view:'new')[:forms]
    assert_raises(A::Error) { call(@alice,'reply',{id:p.id,body:'x'}) }
    assert_raises(A::Error) { A::Service.call(@admin,'moderate',{'kind'=>'Post','id'=>p.id,'status'=>'hidden','reason'=>'x'}) }
    assert_empty A::Event.all
    SiteSetting.whisper_admin_only=true
    assert_raises(Discourse::InvalidAccess) { state(@alice) }
    assert state(@admin)[:admin]
    SiteSetting.whisper_enabled=false
    assert_raises(Discourse::InvalidAccess) { state(@admin) }
  end
  def test_anonymous_entries_parent_context_and_stable_aliases
    p=post;c=reply(p);reply(p,@alice,parent:c);d=reply(p,@carol,parent:c)
    assert_equal ['匿名 A','洞主','匿名 B'],state(@bob,view:'post',id:p.id)[:replies].map { |r| r[:alias] }
    json=state(@bob,view:'post',id:p.id).to_json
    %w[user_id authorId email username whisper_alice whisper_bob whisper_carol].each { |s| refute_includes json,s }
    call(@admin,'moderate',{kind:'Comment',id:c.id,status:'hidden',reason:'测试隐藏'})
    s=state(@carol,view:'post',id:p.id)
    assert_equal '这条回复已隐藏',s[:replies].first[:body]
    assert_equal '该回复已隐藏或删除',s[:replies].last[:parent][:excerpt]
    assert_equal '匿名 B',s[:replies].last[:alias]
    assert_equal c.body,state(@admin,view:'post',id:p.id)[:replies].first[:body]
    c2=reply(p,@bob);assert_equal '匿名 A',A::Service.alias_name(p,c2.user_id)
    other=post(@carol);reply(other,@bob);assert_equal '匿名 A',A::Service.alias_name(other,@bob.id)
  end
  def test_visibility_hidden_owner_search_and_media
    p=post;other=post(@bob)
    image=A::Media.create!(user_id:@alice.id,bytes:'jpeg',size:4,token:SecureRandom.hex(24));p.update!(media_ids:[image.id])
    call(@admin,'moderate',{kind:'Post',id:p.id,status:'hidden',reason:'测试'})
    assert_includes state(@alice)[:rows].map { |r| r[:id] },p.id
    refute_includes state(@bob)[:rows].map { |r| r[:id] },p.id
    refute_includes state(@alice,q:'匿名')[:rows].map { |r| r[:id] },p.id
    assert_raises(Discourse::InvalidAccess) { state(@bob,view:'post',id:p.id) }
    assert A::Service.media_allowed?(@alice,image)
    assert A::Service.media_allowed?(@admin,image)
    refute A::Service.media_allowed?(@bob,image)
    assert_raises(Discourse::InvalidAccess) { call(@bob,'react',{kind:'Post',id:p.id,value:1}) }
    call(@alice,'delete_own',{kind:'Post',id:p.id});assert_equal 'deleted',p.reload.status
  end
  def test_exact_sort_and_continuous_feed_pages
    old=post;old.update!(created_at:3.days.ago,last_comment_at:2.days.ago)
    newer=post;newer.update!(created_at:1.hour.ago,last_comment_at:nil)
    active=post;active.update!(created_at:4.days.ago,last_comment_at:1.day.ago)
    assert_equal [newer.id,old.id,active.id],state[:rows].map { |p| p[:id] }
    assert_equal [active.id,old.id,newer.id],state(sort:'active')[:rows].map { |p| p[:id] }
    22.times { |i| post(body:"分页记录 #{i}") }
    first=state;second=state(page:2)
    assert_equal 20,first[:rows].length;assert_equal 5,second[:rows].length
    assert_empty first[:rows].map { |r| r[:id] } & second[:rows].map { |r| r[:id] }
    assert_equal 2,first[:pagination][:next]
  end
  def test_reply_pagination_and_personal_replies
    p=post
    51.times { reply(p) }
    c=A::Comment.last
    detail=state(@bob,view:'post',id:p.id,reply:c.id)
    assert_equal 2,detail[:pagination][:page]
    assert_equal 52,detail[:replies].first[:floor]
    assert_equal 51,state(@bob,view:'mine',part:'replies')[:pagination][:total]
    assert_equal 0,state(@carol,view:'mine',part:'replies')[:pagination][:total]
  end
  def test_reactions_mutually_exclusive_and_like_notifications_aggregate
    p=post;c=reply(p)
    call(@bob,'react',{kind:'Post',id:p.id,value:1});call(@carol,'react',{kind:'Post',id:p.id,value:1})
    inbox=A::Inbox.where(kind:'POST_LIKE');assert_equal 1,inbox.count;assert_equal '已收到 2 个赞',inbox.first.message
    call(@bob,'react',{kind:'Post',id:p.id,value:-1})
    assert_equal [1,-1].sort,A::Reaction.where(target_kind:'Post').pluck(:value).sort
    before=A::Inbox.count;call(@alice,'react',{kind:'Comment',id:c.id,value:1});assert_equal before,A::Inbox.count
    call(@carol,'react',{kind:'Post',id:p.id,value:0});assert_equal 1,A::Reaction.where(target_kind:'Post').count
  end
  def test_reports_deduplication_resolution_and_reopening
    p=post
    2.times { call(@bob,'report',{kind:'Post',id:p.id,reason:'原因'}) }
    assert_equal 1,A::Report.count;assert_equal 1,A::Inbox.where(kind:'POST_REPORT').count
    report=A::Report.first
    assert_raises(Discourse::InvalidAccess) { call(@bob,'resolve_report',{id:report.id}) }
    call(@admin,'resolve_report',{id:report.id});assert report.reload.handled_at
    assert_equal 1,A::Inbox.where(user_id:@bob.id,kind:'REPORT_RESOLVED').count
    call(@bob,'report',{kind:'Post',id:p.id,reason:'再次举报'})
    assert_nil report.reload.handled_at;assert_equal 1,A::Report.count
    assert_equal 1,state(@admin,view:'admin',part:'reports')[:rows].size
    refute_includes state(@admin,view:'admin',part:'reports').to_json,@bob.username
  end
  def test_audited_reveal_does_not_survive_permission_revocation
    p=post;key=SecureRandom.uuid
    assert_raises(Discourse::InvalidAccess) { call(@bob,'reveal',{id:p.id,reason:'x'}) }
    assert_raises(A::Error) { call(@admin,'reveal',{id:p.id,reason:''}) }
    result=call(@admin,'reveal',{id:p.id,reason:'核查测试'},key:key)
    assert_includes result[:message],@alice.username
    call(@admin,'reveal',{id:p.id,reason:'核查测试'},key:key)
    assert_equal 1,A::Audit.where(action:'reveal_identity').count
    assert_equal '核查测试',state(@bob,view:'post',id:p.id)[:audits].first[:reason]
    refute_includes state(@bob,view:'post',id:p.id).to_json,@alice.username
    @group.add(@admin);@admin.update!(admin:false);@admin.reload
    assert_raises(Discourse::InvalidAccess) { call(@admin,'reveal',{id:p.id,reason:'核查测试'},key:key) }
  end
  def test_bans_and_deletion_ownership
    p=post;c=reply(p)
    call(@admin,'ban',{username:@bob.username,banned:true,reason:'测试限制'})
    assert state(@bob)[:banned]
    assert_empty state(@bob,view:'new')[:forms]
    assert_raises(A::Error) { call(@bob,'react',{kind:'Post',id:p.id,value:1}) }
    assert_raises(A::Error) { call(@bob,'reply',{id:p.id,body:'x'}) }
    assert_raises(Discourse::InvalidAccess) { call(@bob,'delete_own',{kind:'Post',id:p.id}) }
    call(@bob,'delete_own',{kind:'Comment',id:c.id});assert_equal 'deleted',c.reload.status
    call(@bob,'mark_read');assert_equal 0,A::Inbox.where(user_id:@bob.id,read:false).count
  end
  def test_idempotence_and_input_validation
    key=SecureRandom.uuid
    a=call(@alice,'post',{body:'唯一正文'},key:key);b=call(@alice,'post',{body:'唯一正文'},key:key)
    assert_equal a.deep_stringify_keys,b;assert_equal 1,A::Post.count
    assert_match(/\A[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}\z/,A::Post.first.public_code)
    assert_raises(A::Error) { call(@alice,'post',{body:'另一个'},key:key) }
    assert_raises(A::Error) { call(@alice,'post',{body:'x'*4001}) }
    p=post;other=post;c=reply(other)
    assert_raises(A::Error) { reply(p,parent:c) }
    assert_raises(Discourse::NotFound) { state(view:'unknown') }
  end
  def fixture
    time='2026-08-01T12:00:00.123Z'
    {'format'=>'riverside-community-v1','project'=>'whisper','media'=>[],'tables'=>{
      'User'=>[{'id'=>'u1','externalUserId'=>@alice.id.to_s},{'id'=>'u2','externalUserId'=>@bob.id.to_s}],
      'Post'=>[{'id'=>'p1','authorId'=>'u1','publicCode'=>'ABCDE','body'=>'旧正文','title'=>nil,'status'=>'VISIBLE','imageUrls'=>[],'lastCommentAt'=>time,'createdAt'=>time,'updatedAt'=>time}],
      'Comment'=>[{'id'=>'c1','postId'=>'p1','authorId'=>'u2','parentId'=>nil,'body'=>'旧回复','status'=>'VISIBLE','createdAt'=>time,'updatedAt'=>time}],
      'Reaction'=>[{'id'=>'r1','userId'=>'u2','postId'=>'p1','commentId'=>nil,'targetType'=>'POST','type'=>'LIKE','createdAt'=>time}],
      'Report'=>[],'IdentityRevealAudit'=>[],'ModerationEvent'=>[],
      'Notification'=>[{'id'=>'n1','userId'=>'u1','postId'=>'p1','commentId'=>'c1','type'=>'COMMENT_REPLY','read'=>false,'message'=>nil,'createdAt'=>time}]}}
  end
  def test_import_preserves_history_timestamps_aliases_and_no_bell_replay
    SiteSetting.whisper_enabled=false;data=fixture
    importer=A::Importer.new(data)
    importer.run(sha:'test');assert_equal 0,A::Post.count
    result=A::Importer.new(data).run(sha:'test',apply:true,expected_sha:'test')
    assert_equal 1,A::Post.count;assert_equal 1,A::Inbox.count;assert_equal 0,A::Event.count
    assert_equal Time.iso8601(data['tables']['Reaction'][0]['createdAt']),A::Reaction.first.created_at
    assert A::Inbox.first.historical;refute A::Inbox.first.read
    assert_equal '匿名 A',A::Service.alias_name(A::Post.first,@bob.id)
    assert A::Importer.new(data).run(sha:'test',apply:true,expected_sha:'test')[:already_imported]
    SiteSetting.whisper_enabled=true;A::Shared.deliver;assert_equal 0,A::Event.count
    assert_equal 1,state(@alice,view:'notifications')[:rows].length
    assert_empty state(@bob,view:'notifications')[:rows]
  end
  def test_missing_media_requires_explicit_manifest_acceptance
    SiteSetting.whisper_enabled=false;data=fixture
    data['tables']['Post'][0]['imageUrls']=['missing.jpg'];data['media']=[{'name'=>'missing.jpg','missing'=>true}]
    assert_raises(A::Error) { A::Importer.new(data,directory:'/tmp').run(sha:'missing',apply:true,expected_sha:'missing') }
    assert_equal 0,A::Post.count
    A::Importer.new(data,directory:'/tmp',allow_missing_media:true).run(sha:'missing',apply:true,expected_sha:'missing')
    assert_equal 1,A::Post.first.missing_media_count;assert_empty A::Post.first.media_ids
  end
  def test_lifecycle_erases_identity_and_cached_reveal
    p=post;c=reply(p);call(@admin,'reveal',{id:p.id,reason:'测试'})
    A::Legacy.create!(source:'User',legacy_id:'old-alice',data:{externalUserId:@alice.id.to_s,forumUsername:@alice.username})
    A::Legacy.create!(source:'Post',legacy_id:'old-post',target_kind:'Post',target_id:p.id,data:{authorId:'old-alice',body:p.body})
    export=A::UserLifecycle.export(@alice.id)
    assert_equal 1,export[:posts].size;assert_empty export[:comments]
    A::UserLifecycle.purge(@alice.id)
    assert_equal 'deleted',p.reload.status;refute_equal @alice.id,p.user_id
    assert_empty A::Legacy.all
    assert_empty A::Command.where("result->>'identity_user_id' = ?",@alice.id.to_s)
    assert_equal '认真回复',c.reload.body
    assert_empty A::Audit.first.details
  end
  def test_anonymization_preserves_content_without_private_identity
    p=post;c=reply(p)
    A::UserLifecycle.purge(@bob.id,erase_content:false)
    assert_equal '认真回复',c.reload.body;refute_equal @bob.id,c.user_id
    assert_equal '匿名 A',A::Service.alias_name(p,c.user_id)
    assert_empty A::Inbox.where(user_id:@bob.id)
  end
  def test_legacy_routes_whitelist_and_reply_lookup
    p=post
    A::Legacy.create!(source:'Post',legacy_id:'old-post',target_kind:'Post',target_id:p.id,data:{})
    assert_equal({view:'post',id:p.id},A::Service.legacy_query('post/old-post'))
    assert_equal({view:'feed'},A::Service.legacy_query('auth/callback',{'sso'=>'private','sig'=>'private'}))
    assert_equal({view:'admin',part:'reports'},A::Service.legacy_query('admin',{'tab'=>'reports'}))
  end
  def test_delivery_hides_actor_and_read_state_stays_scoped
    p=post;reply(p)
    A::Shared.deliver
    event=A::Event.first;n=Notification.find(event.notification_id)
    refute_includes n.data,@bob.username
    refute_includes n.data,'认真回复'
    assert_includes JSON.parse(n.data)['river_path'],"view=post&id=#{p.id}"
    call(@bob,'mark_read');refute A::Inbox.first.reload.read
    call(@alice,'mark_read');assert A::Inbox.first.reload.read;assert n.reload.read
  end
  def test_http_privacy_and_protected_images
    p=post
    bytes=Vips::Image.black(4,4).new_from_image([100,160,200]).jpegsave_buffer
    image=A::Media.create!(user_id:@alice.id,bytes:bytes,size:bytes.bytesize,token:SecureRandom.hex(24));p.update!(media_ids:[image.id])
    session=ActionDispatch::Integration::Session.new(Rails.application);session.host!('community.test')
    key=ApiKey.create!(user:@bob,created_by:@admin,description:'Disposable whisper HTTP test')
    headers={'HTTP_API_KEY'=>key.key,'HTTP_X_REQUESTED_WITH'=>'XMLHttpRequest'}
    session.get('/whisper/state.json',headers:headers)
    assert_equal 200,session.response.status
    refute_includes session.response.body,@alice.username
    session.get("/whisper/media/#{image.id}",headers:headers)
    assert_equal 200,session.response.status
    assert_includes session.response.headers['Cache-Control'],'no-store'
    assert_equal bytes,session.response.body.b
    session.get("/whisper/media/#{image.id}")
    assert_equal 403,session.response.status
    call(@admin,'moderate',{kind:'Post',id:p.id,status:'hidden',reason:'测试隐藏图片'})
    session.get("/whisper/media/#{image.id}",headers:headers)
    assert_equal 403,session.response.status
  ensure
    key&.destroy!
  end
  def test_media_limits_ownership_and_account_purge
    p=post
    media=Array.new(9) { A::Media.create!(user_id:@alice.id,bytes:'jpg',size:3,token:SecureRandom.hex(24)) }
    assert_equal 9,A::Shared.media_ids(@alice,media.map(&:id)).size
    assert_raises(A::Error) { A::Shared.media_ids(@bob,[media.first.id]) }
    extra=A::Media.create!(user_id:@alice.id,bytes:'jpg',size:3,token:SecureRandom.hex(24))
    assert_raises(A::Error) { A::Shared.media_ids(@alice,(media+[extra]).map(&:id)) }
    p.update!(media_ids:[media.first.id]);other=post(@bob);other.update!(media_ids:[media.first.id])
    A::UserLifecycle.purge(@alice.id)
    assert_empty other.reload.media_ids
    assert_empty A::Media.where(user_id:@alice.id)
  end

end
