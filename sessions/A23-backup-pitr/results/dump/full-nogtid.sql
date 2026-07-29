-- MySQL dump 10.13  Distrib 8.4.3, for Linux (aarch64)
--
-- Host: localhost    Database: spoon
-- ------------------------------------------------------
-- Server version	8.4.3

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Current Database: `spoon`
--

CREATE DATABASE /*!32312 IF NOT EXISTS*/ `spoon` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci */ /*!80016 DEFAULT ENCRYPTION='N' */;

USE `spoon`;

--
-- Table structure for table `audit_log`
--

DROP TABLE IF EXISTS `audit_log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `audit_log` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `msg` varchar(100) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=51 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `audit_log`
--

LOCK TABLES `audit_log` WRITE;
/*!40000 ALTER TABLE `audit_log` DISABLE KEYS */;
INSERT INTO `audit_log` VALUES (1,'after-incident-1'),(2,'after-incident-2'),(3,'after-incident-3'),(4,'after-incident-4'),(5,'after-incident-5'),(6,'after-incident-6'),(7,'after-incident-7'),(8,'after-incident-8'),(9,'after-incident-9'),(10,'after-incident-10'),(11,'after-incident-11'),(12,'after-incident-12'),(13,'after-incident-13'),(14,'after-incident-14'),(15,'after-incident-15'),(16,'after-incident-16'),(17,'after-incident-17'),(18,'after-incident-18'),(19,'after-incident-19'),(20,'after-incident-20'),(21,'after-incident-21'),(22,'after-incident-22'),(23,'after-incident-23'),(24,'after-incident-24'),(25,'after-incident-25'),(26,'after-incident-26'),(27,'after-incident-27'),(28,'after-incident-28'),(29,'after-incident-29'),(30,'after-incident-30'),(31,'after-incident-31'),(32,'after-incident-32'),(33,'after-incident-33'),(34,'after-incident-34'),(35,'after-incident-35'),(36,'after-incident-36'),(37,'after-incident-37'),(38,'after-incident-38'),(39,'after-incident-39'),(40,'after-incident-40'),(41,'after-incident-41'),(42,'after-incident-42'),(43,'after-incident-43'),(44,'after-incident-44'),(45,'after-incident-45'),(46,'after-incident-46'),(47,'after-incident-47'),(48,'after-incident-48'),(49,'after-incident-49'),(50,'after-incident-50');
/*!40000 ALTER TABLE `audit_log` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-07-29  6:14:59
