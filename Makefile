include $(TOPDIR)/rules.mk

PKG_NAME:=parental-suite
PKG_VERSION:=2.1.2
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt Parental Suite Team
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/parental-suite
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  TITLE:=Parental Suite v2 (API-first)
  DEPENDS:=+curl +nftables +luci-lib-jsonc +ip-full +busybox
endef

define Package/parental-suite/description
 The Parental Suite v2 provides nftables-based scheduling, a web UI,
 Telegram bot, and AdGuard Home integration for OpenWrt routers.
endef

define Package/parental-suite/conffiles
/etc/config/parental
endef

define Package/parental-suite/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./etc/config/parental $(1)/etc/config/parental

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./etc/init.d/parental $(1)/etc/init.d/parental

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./usr/libexec/rpcd/parental $(1)/usr/libexec/rpcd/parental

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./usr/share/rpcd/acl.d/parental.json $(1)/usr/share/rpcd/acl.d/parental.json

	$(INSTALL_DIR) $(1)/usr/share/parental/scripts
	$(INSTALL_BIN) ./usr/share/parental/scripts/*.sh $(1)/usr/share/parental/scripts/

	$(INSTALL_DIR) $(1)/usr/share/parental/telegram
	$(INSTALL_BIN) ./usr/share/parental/telegram/bot.sh $(1)/usr/share/parental/telegram/bot.sh

	$(INSTALL_DIR) $(1)/www/parental-ui
	$(CP) -a ./www/parental-ui/. $(1)/www/parental-ui/
endef

$(eval $(call BuildPackage,parental-suite))
