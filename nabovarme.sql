-- MySQL dump 10.13  Distrib 5.5.62, for debian-linux-gnu (x86_64)
--
-- Host: localhost    Database: nabovarme
-- ------------------------------------------------------
-- Server version	5.5.62-0+deb8u1

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `accounts`
--

DROP TABLE IF EXISTS `accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `accounts` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `type` enum('payment','membership','charge') COLLATE utf8mb4_unicode_ci DEFAULT 'payment',
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT '0',
  `info` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT '',
  `price` float NOT NULL DEFAULT '1',
  `auto` tinyint(1) DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_idx` (`serial`,`payment_time`,`amount`,`price`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=2172 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts_auto`
--

DROP TABLE IF EXISTS `accounts_auto`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `accounts_auto` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT '0',
  `info_row` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `info_detail` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `price` float NOT NULL DEFAULT '1',
  `phone` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `state` enum('new','partially_parsed','parsed','accounted','ignored','error') COLLATE utf8mb4_unicode_ci DEFAULT 'new',
  `screenshot_row` longblob,
  `screenshot_detail` longblob,
  `info_row_hash` bigint(12) DEFAULT NULL,
  `info_detail_hash` bigint(12) DEFAULT NULL,
  `info_row_phash` varchar(512) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `duplicate_count` int(11) DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_idx` (`serial`,`payment_time`,`amount`,`price`),
  UNIQUE KEY `unique_info_row_idx` (`info_row_hash`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=3416 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts_auto_payers_learned`
--

DROP TABLE IF EXISTS `accounts_auto_payers_learned`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `accounts_auto_payers_learned` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `phone` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `comment` longtext COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `alarms`
--

DROP TABLE IF EXISTS `alarms`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `alarms` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) NOT NULL DEFAULT '1',
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `condition` longtext COLLATE utf8mb4_unicode_ci NOT NULL,
  `last_notification` int(11) DEFAULT NULL,
  `alarm_state` int(1) unsigned NOT NULL DEFAULT '0',
  `repeat` int(11) NOT NULL DEFAULT '0',
  `snooze` int(11) NOT NULL DEFAULT '0',
  `default_snooze` int(11) NOT NULL DEFAULT '1800',
  `snooze_auth_key` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `sms_notification` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `down_message` longtext COLLATE utf8mb4_unicode_ci,
  `up_message` longtext COLLATE utf8mb4_unicode_ci,
  `comment` longtext COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=58 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `command_queue`
--

DROP TABLE IF EXISTS `command_queue`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `command_queue` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `function` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `param` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  `state` enum('sent','received','timeout') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'sent',
  `has_callback` tinyint(1) NOT NULL DEFAULT '0',
  `timeout` int(11) NOT NULL DEFAULT '0',
  `sent_count` int(11) NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=195767784 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `log`
--

DROP TABLE IF EXISTS `log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `log` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `function` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `param` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=35995078 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meter_groups`
--

DROP TABLE IF EXISTS `meter_groups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `meter_groups` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `group` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meters`
--

DROP TABLE IF EXISTS `meters`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `meters` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) DEFAULT '1',
  `type` enum('heat','water','electricity','aggregated','heat_supply','heat_sub') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'heat',
  `group` int(3) unsigned NOT NULL DEFAULT '0',
  `parent_serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `info` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `setup_value` float NOT NULL DEFAULT '0',
  `setup_hours` int(11) DEFAULT '0',
  `sw_version` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `key` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `valve_status` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `valve_installed` tinyint(1) NOT NULL DEFAULT '1',
  `last_updated` int(11) DEFAULT '0',
  `uptime` int(11) DEFAULT NULL,
  `reset_reason` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ssid` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `rssi` int(8) DEFAULT NULL,
  `min_amount` float NOT NULL DEFAULT '0',
  `default_price` float NOT NULL DEFAULT '1',
  `email_notification` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `sms_notification` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `close_notification_time` int(11) DEFAULT '604800' COMMENT 'send notice this many seconds before we close (default 7 days)',
  `notification_state` int(1) unsigned NOT NULL DEFAULT '0',
  `notification_sent_at` float DEFAULT NULL,
  `wifi_status` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT 'disconnected',
  `wifi_set_ssid` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `wifi_set_pwd` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ap_status` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `location_lat` decimal(12,8) DEFAULT NULL,
  `location_long` decimal(12,8) DEFAULT NULL,
  `comment` longtext COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=328 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples`
--

DROP TABLE IF EXISTS `samples`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `samples` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=298034942 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples_cache`
--

DROP TABLE IF EXISTS `samples_cache`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `samples_cache` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=297783923 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples_calculated`
--

DROP TABLE IF EXISTS `samples_calculated`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `samples_calculated` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=3857986737 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `sms_auth`
--

DROP TABLE IF EXISTS `sms_auth`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `sms_auth` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `cookie_token` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `session` tinyint(1) NOT NULL DEFAULT '0',
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `auth_state` set('new','login','sms_code_sent','sms_code_verified','deny') COLLATE utf8mb4_unicode_ci DEFAULT 'new',
  `phone` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `sms_code` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `orig_uri` longtext COLLATE utf8mb4_unicode_ci,
  `remote_host` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `user_agent` longtext COLLATE utf8mb4_unicode_ci,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=428845 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `users`
--

DROP TABLE IF EXISTS `users`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `users` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `password` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `admin_group` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `name` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `mail` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `phone` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `address` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `meter_id` int(255) DEFAULT NULL,
  `comment` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=86 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `wifi_scan`
--

DROP TABLE IF EXISTS `wifi_scan`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `wifi_scan` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ssid` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `bssid` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `rssi` int(11) DEFAULT NULL,
  `channel` int(11) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=90947432 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2020-11-30 22:47:09
