import { apiInitializer } from "discourse/lib/api";
import CustomNotification from "discourse/lib/notification-types/custom";
export default apiInitializer((api) => {
  api.registerNotificationTypeRenderer("custom", () => class extends CustomNotification {
    get isRiver() { return this.notification.data.river_app || this.notification.data.rsc; }
    get description() { return this.isRiver ? (this.notification.data.river_text || this.notification.data.topic_title) : super.description; }
    get linkHref() { return this.isRiver && !this.topicId ? (this.notification.data.river_path || this.notification.data.rsc_path) : super.linkHref; }
    get icon() { return this.isRiver ? (this.notification.data.river_icon || "coins") : super.icon; }
    get label() { return this.notification.data.river_app ? "" : super.label; }
    get linkTitle() { return this.isRiver ? this.description : super.linkTitle; }
  });
});
