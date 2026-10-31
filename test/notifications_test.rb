# frozen_string_literal: true
abort 'Disposable database only' unless ENV['RIVER_DISPOSABLE']=='1' && GlobalSetting.db_name=='river_community_test'
require 'minitest/autorun'
class WhisperNotificationsTest < Minitest::Test
  A=DiscourseWhisper
  def with_stub(receiver,name,implementation)
    original=receiver.method(name)
    receiver.define_singleton_method(name,implementation)
    yield
  ensure
    receiver.define_singleton_method(name,original) if original
  end
  def setup
    A::Event.delete_all
    @user=User.find_by(username:'outbox_admin') || User.create!(username:'outbox_admin',email:'outbox@example.invalid',password:SecureRandom.hex(32),active:true,approved:true,admin:true)
    SiteSetting.whisper_enabled=true
    SiteSetting.whisper_read_only=false
  end
  def event(text='消息',user_id:@user.id)
    A::Event.create!(user_id:user_id,key:SecureRandom.uuid,text:text,path:'/whisper')
  end
  def test_readonly_pause_then_exactly_once_delivery
    row=event
    SiteSetting.whisper_read_only=true
    A::Notifications.deliver
    assert_nil row.reload.notification_id
    SiteSetting.whisper_read_only=false
    A::Notifications.deliver
    id=row.reload.notification_id
    assert id
    A::Notifications.deliver
    assert_equal id,row.reload.notification_id
  end
  def test_unavailable_recipient_cannot_starve_later_events
    100.times { event(user_id:999_999_999) }
    good=event
    A::Notifications.deliver
    A::Notifications.deliver
    assert good.reload.notification_id
    assert_equal 100,A::Event.where(last_error_class:'RecipientUnavailable').count
    assert_equal 0,A::Notifications.pending.count
  end
  def test_one_failure_defers_only_that_event
    bad=event('失败');good=event('成功')
    original=Notification.method(:create!)
    with_stub(Notification,:create!, ->(**attrs) { raise IOError,'test only' if attrs[:data].include?('失败');original.call(**attrs) }) do
      A::Notifications.deliver
    end
    assert_nil bad.reload.notification_id
    assert_equal 1,bad.attempts
    assert_operator bad.next_attempt_at,:>,Time.current
    assert good.reload.notification_id
    bad.update!(next_attempt_at:Time.current)
    A::Notifications.deliver
    assert bad.reload.notification_id
    assert_nil bad.last_error_class
  end
  def test_enqueue_failure_does_not_raise_to_caller
    Discourse.redis.del('whisper:notification-enqueue')
    with_stub(Jobs,:enqueue, ->(*) { raise IOError,'queue unavailable' }) do
      A::Notifications.enqueue
    end
    assert true
  end
end
