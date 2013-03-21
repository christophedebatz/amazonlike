-- hide all warning console messages
SET client_min_messages TO WARNING;

-- import pgcrypto librairy
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- drop database and functions
DROP DATABASE IF EXISTS bddprojectdb;

-- drop all the tables to reconstruct each
DROP TABLE IF EXISTS amz_categories CASCADE;
DROP TABLE IF EXISTS amz_pictures CASCADE;
DROP TABLE IF EXISTS amz_products CASCADE;
DROP TABLE IF EXISTS amz_customers CASCADE;
DROP TABLE IF EXISTS amz_comments CASCADE;
DROP TABLE IF EXISTS amz_orders CASCADE;
DROP TABLE IF EXISTS amz_payments CASCADE;

-- drop types and variables
DROP TYPE IF EXISTS ORDER_STATUS CASCADE;
DROP TYPE IF EXISTS PAYMENT_STATUS CASCADE;

-- drop users and roles and groups
DROP USER IF EXISTS christophe;
DROP USER IF EXISTS benjamin;
DROP USER IF EXISTS julien;
DROP GROUP IF EXISTS administrators;
DROP GROUP IF EXISTS users;

-- drop sequences
DROP SEQUENCE IF EXISTS amz_productsSQ CASCADE;
DROP SEQUENCE IF EXISTS amz_customersSQ CASCADE;
DROP SEQUENCE IF EXISTS amz_ordersSQ CASCADE;

-- create the main database
CREATE DATABASE bddprojectdb;

-- create new types that we will use
CREATE TYPE ORDER_STATUS 
	AS ENUM ('validated', 'sent', 'received', 'cancelled', 'unavailable');
	
CREATE TYPE PAYMENT_STATUS
	AS ENUM ('accepted', 'rejected', 'cancelled', 'unknown');

--
-- amz_pictures (3rd normalized)
-- stock all the pictures that we need for the platform
--
CREATE TABLE IF NOT EXISTS amz_pictures (
	pic_url VARCHAR(250) PRIMARY KEY CHECK (pic_url LIKE 'https://cluster%.akamai-hd.com/%'),
	pic_width INTEGER CHECK (pic_width > 0 AND pic_width < 1000),
	pic_height INTEGER CHECK (pic_height > 0 AND pic_height < 700),
	pic_size REAL NOT NULL
);
CREATE INDEX amz_pictures_index ON amz_pictures (pic_url); -- hash based index
-- no clustering here because of hash hash index type



--
-- amz_categories (3rd normalized)
-- stock the main categories of products
--
CREATE TABLE IF NOT EXISTS amz_categories (
	cat_name VARCHAR(50) PRIMARY KEY,
	cat_pic_url VARCHAR(250) DEFAULT NULL REFERENCES amz_pictures (pic_url) ON DELETE SET DEFAULT
);
CREATE INDEX amz_categories_index ON amz_categories USING hash (cat_name); -- hash based index
-- no clustering here because of hash hash index type



--
-- amz_products
-- stock all the products that the shop is offering
--
CREATE SEQUENCE amz_productsSQ START 0 INCREMENT BY 1 MINVALUE 0 NO MAXVALUE;
CREATE TABLE IF NOT EXISTS amz_products (
	prod_id SERIAL PRIMARY KEY,
	prod_price MONEY NOT NULL,
	prod_cat_name VARCHAR(50) REFERENCES amz_categories (cat_name) ON DELETE CASCADE, -- cascade = clear all products of a category when removing this category
	prod_designer VARCHAR(30),
	prod_name VARCHAR(40) UNIQUE NOT NULL,
	prod_description TEXT,
	prod_pic_url VARCHAR(250) DEFAULT NULL REFERENCES amz_pictures(pic_url) ON DELETE SET DEFAULT,
	prod_stock SMALLINT
);

CREATE INDEX amz_products_index1 ON amz_products USING hash (prod_id); -- hash based index
CREATE INDEX amz_products_index2 ON amz_products (prod_name); -- b-tree based index
CLUSTER amz_products USING amz_products_index2;



--
-- amz_customers
-- stock all the customer accounts
--
CREATE SEQUENCE amz_customersSQ START 0 INCREMENT BY 1 MINVALUE 0 NO MAXVALUE;
CREATE TABLE IF NOT EXISTS amz_customers (
	cust_id SERIAL PRIMARY KEY,
	cust_name VARCHAR(50) NOT NULL,
	cust_email VARCHAR(60) NOT NULL CHECK (cust_email LIKE '%@%'),
	cust_password VARCHAR(60) NOT NULL CHECK (cust_password <> cust_name OR cust_password <> cust_phone), 
	cust_adress VARCHAR(60) NOT NULL,
	cust_phone VARCHAR(10) DEFAULT NULL CHECK(cust_phone IS NULL OR char_length(cust_phone) = 10),
	cust_pic_url VARCHAR(250) DEFAULT NULL REFERENCES amz_pictures (pic_url) ON DELETE RESTRICT,
	cust_nb_order SMALLINT DEFAULT 0,
	UNIQUE (cust_name, cust_email)
);
CREATE INDEX amz_customers_index1 ON amz_customers USING hash (cust_id); -- hash based index
CREATE INDEX amz_customers_index2 ON amz_customers (cust_name); -- b-tree based index
CLUSTER amz_customers USING amz_customers_index2;



--
-- amz_comments (3rd normalized)
-- stock all the comments about some products
--
CREATE TABLE IF NOT EXISTS amz_comments (
	com_cust_id INTEGER REFERENCES amz_customers (cust_id) ON DELETE CASCADE, -- del when user disappears
	com_prod_id INTEGER REFERENCES amz_products (prod_id) ON DELETE CASCADE, -- del when product disappers
	com_grade SMALLINT NULL CHECK (com_grade IS NULL OR com_grade BETWEEN 0 AND 5),
	com_date DATE DEFAULT CURRENT_DATE,
	com_text VARCHAR(250) NULL,
	PRIMARY KEY (com_cust_id, com_prod_id, com_date)
);
CREATE INDEX amz_comments_index ON amz_comments (com_cust_id, com_prod_id, com_date); -- b-tree based index
CLUSTER amz_comments USING amz_comments_index;



--
-- amz_orders
-- stock all information about the orders
--
CREATE SEQUENCE amz_ordersSQ START 0 INCREMENT BY 1 MINVALUE 0 NO MAXVALUE;
CREATE TABLE IF NOT EXISTS amz_orders (
	ord_id SERIAL PRIMARY KEY,
	ord_date VARCHAR(50),
	ord_product_id INTEGER,
	ord_buyer_id INTEGER NOT NULL REFERENCES amz_customers(cust_id) ON DELETE RESTRICT CHECK (ord_buyer_id <> ord_seller_id),
	ord_seller_id INTEGER NOT NULL REFERENCES amz_customers(cust_id) ON DELETE RESTRICT CHECK (ord_buyer_id <> ord_seller_id),
	ord_grade SMALLINT NULL CHECK (ord_grade IS NULL OR ord_grade BETWEEN 0 AND 5),
	ord_status ORDER_STATUS DEFAULT 'unavailable'
);
CREATE INDEX amz_orders_index1 ON amz_orders USING hash (ord_id); -- hash based index
CREATE INDEX amz_orders_index2 ON amz_orders (ord_date); -- b-tree based index
CLUSTER amz_orders USING amz_orders_index2;



--
-- amz_payments (3rd normalized)
-- stock all the transactions of payment
--
CREATE TABLE IF NOT EXISTS amz_payments (
	pay_ord_id INTEGER REFERENCES amz_orders (ord_id) ON DELETE CASCADE,
	pay_date DATE NOT NULL,
	pay_bank VARCHAR(50) NOT NULL, 
	pay_cbcrypto SMALLINT NOT NULL CHECK (pay_cbcrypto > 0),
	pay_devise CHAR(3) NOT NULL CHECK (pay_devise IN ('EUR', 'USD', 'CAD', 'YEN', 'CHF', 'NOK')),
	pay_status PAYMENT_STATUS DEFAULT 'unknown',
	PRIMARY KEY (pay_ord_id, pay_date)
);
CREATE INDEX amz_payments_index ON amz_payments(pay_date, pay_status); -- b-tree based index
CLUSTER amz_payments USING amz_payments_index;


	
--
-- trigger function control - BEFORE INSERT INTO amz_comments
-- check if the commenter have bought or sell (so, testing) the product
--
CREATE OR REPLACE FUNCTION checkCommentProcess () 
RETURNS TRIGGER AS '
	BEGIN
		IF NEW.com_cust_id IN (SELECT cust_id FROM amz_orders 
						LEFT JOIN amz_customers 
							ON ord_seller_id = cust_id 
					WHERE ord_buyer_id = NEW.com_cust_id 
					OR ord_seller_id = NEW.com_cust_id) THEN
			RETURN NEW;
		ELSE
			RAISE EXCEPTION ''Cannot post a comment before buy or sell this product!'';
		END IF;
	END;
' LANGUAGE 'plpgsql';

CREATE TRIGGER checkComment BEFORE INSERT ON amz_comments 
	FOR EACH ROW EXECUTE PROCEDURE checkCommentProcess();


--
-- trigger function control - AFTER INSERT INTO amz_payments
-- check if the payment is done and mark it in orders table
--
CREATE OR REPLACE FUNCTION considerPaymentProcess () 
RETURNS TRIGGER AS '
	BEGIN
		IF NEW.pay_status = ''accepted'' THEN
			UPDATE amz_orders SET ord_status = ''validated'' WHERE ord_id = NEW.pay_ord_id;
			RETURN NEW;
		ELSE
			RAISE EXCEPTION ''Cannot consider this payment because of its current status!'';
		END IF;
	END;
' LANGUAGE 'plpgsql';

CREATE TRIGGER considerPayment AFTER INSERT ON amz_payments
	FOR EACH ROW EXECUTE PROCEDURE considerPaymentProcess();
	

--
-- trigger function control - AFTER DELETE ON amz_payments
-- when a payment is deleted, it marks it on the orders table, on the well order
--
CREATE OR REPLACE FUNCTION removePaymentOrderProcess () 
RETURNS TRIGGER AS '
	BEGIN
		UPDATE amz_orders SET ord_status = ''unavailable'' WHERE order_id = OLD.pay_ord_id;
	END;
' LANGUAGE 'plpgsql';

CREATE TRIGGER removePaymentOrder AFTER DELETE ON amz_payments
	FOR EACH ROW EXECUTE PROCEDURE removePaymentOrderprocess();


--
-- standard function
-- encode all passwords with sha1 algorithm
--
CREATE OR REPLACE FUNCTION SHA1(bytea)
RETURNS character varying AS '
	BEGIN
		RETURN ENCODE(DIGEST($1, ''sha1''), ''hex'');
	END;
' LANGUAGE 'plpgsql';


-- create groups and add users into
CREATE GROUP administrators;
CREATE GROUP moderators;
CREATE GROUP users;

-- create several users for instance
CREATE USER christophe WITH PASSWORD 'chris' IN GROUP administrators;
CREATE USER benjamin WITH PASSWORD 'benji' IN GROUP moderators;
CREATE USER julien IN GROUP users;

-- grants management
GRANT ALL PRIVILEGES ON DATABASE bddprojectdb TO administrators;
GRANT ALL PRIVILEGES ON DATABASE bddprojectdb TO moderators;
GRANT ALL PRIVILEGES ON DATABASE bddprojectdb TO users;
REVOKE UPDATE ON amz_comments, amz_pictures, amz_categories, amz_products, amz_payments, amz_orders FROM users;
REVOKE DELETE ON amz_comments, amz_pictures, amz_categories, amz_products, amz_payments, amz_orders FROM users;
REVOKE UPDATE ON amz_categories, amz_products, amz_payments, amz_orders FROM users; -- grant pictures and comments
REVOKE DELETE ON amz_categories, amz_products, amz_payments, amz_orders FROM users; -- grant pictures and comments


-- fill the pictures table
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img1.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img2.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img3.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img4.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img5.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img6.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img7.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img8.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img9.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img10.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img11.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img12.jpg', 300, 350, 1.5);
INSERT INTO amz_pictures VALUES('https://cluster001.akamai-hd.com/img13.jpg', 300, 350, 1.5);

-- fill the categories
INSERT INTO amz_categories VALUES('Jardinage', 'https://cluster001.akamai-hd.com/img1.jpg');
INSERT INTO amz_categories VALUES('Informatique', 'https://cluster001.akamai-hd.com/img2.jpg');
INSERT INTO amz_categories VALUES('Electromenager', 'https://cluster001.akamai-hd.com/img3.jpg');
INSERT INTO amz_categories VALUES('Bricolage', 'https://cluster001.akamai-hd.com/img4.jpg');

-- fill the customers
INSERT INTO amz_customers VALUES(nextval('amz_customersSQ'), 'Camille', 'camille.t@gmail.com', SHA1('lol'), '12 avenue de la Reine, 78000 Versailles', '0687757602', DEFAULT, DEFAULT);
INSERT INTO amz_customers VALUES(nextval('amz_customersSQ'), 'Christophe', 'christophe.db@gmail.com', SHA1('lol'), '46 rue saint charles, 78000 Versailles', '0687757602', DEFAULT, DEFAULT);
INSERT INTO amz_customers VALUES(nextval('amz_customersSQ'), 'Benjamin', 'bertrand@gmail.com', SHA1('lol'), '55 rue de Sèvres, Sevres', '0687757602', DEFAULT, DEFAULT);
INSERT INTO amz_customers VALUES(nextval('amz_customersSQ'), 'Julien', 'blancj@efrei.fr', SHA1('lol'), '34 rue du Docteur Finlay, 75015 Paris', '0643287654', DEFAULT, DEFAULT);
INSERT INTO amz_customers VALUES(nextval('amz_customersSQ'), 'Amazon.com', 'no-reply@amazon-services.com', SHA1('lol'), 'no-adress', '0000000000', DEFAULT, DEFAULT);

-- fill the products
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 19.99, 'Jardinage', 'MONSANTO', 'Round UP ultra effect', 'Round UP ultra effect permet le désherbage immédiat de vos zones de graviers ou de vos champ de fleurs', DEFAULT, 80);
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 215.00, 'Informatique', 'IIYAMA', 'Ecran 24" HD LED', 'Cet ecran dispose d''une dalle MA 1920x1024, d''un retroeclairage LED et d''''un ecran 24"', 'https://cluster001.akamai-hd.com/img5.jpg', 25);
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 249.00, 'Informatique', 'SONY', 'Console layStation 3', 'La PS3 est la console nouvelle generation 3D de SONY, livre avec 15h de PlayStation Network gratuits.', 'https://cluster001.akamai-hd.com/img6.jpg', 66);
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 229.00, 'Informatique', 'MICROSOFT', 'Console XBOX 360', 'La XBOX 360 est la nouvelle console de Microsoft livree avec le XBOX Live 10h de jeu gratuits et des jeux comme Halo.', 'https://cluster001.akamai-hd.com/img7.jpg', 14);
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 299.00, 'Informatique', 'ASUS', 'Ordinateur X101CH-RED051S', 'Netbook 10.1" LED - Processeur Intel Atom N2600 - Mémoire 1024Mo - Disque Dur 320Go - Webcam 0.3Mpixels - Wifi 802.11 b/g/n - Port HDMI - Ethernet - Lecteur de carte SD - Batterie 3 Cellules - Windows 7 Starter - Garantie 1 an', 'https://cluster001.akamai-hd.com/img8.jpg', 55);
INSERT INTO amz_products VALUES(nextval('amz_productsSQ'), 150.00, 'Informatique', 'NINTENDO', 'Console WII', 'Contient la console Wii Blanche + 1 Wiimote (télécommande Wii) + Dragonne pour Wiimote + 1 Nunchuk + 1 Capteur Wii ', 'https://cluster001.akamai-hd.com/img9.jpg', 12);

-- fill orders
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2012-11-13', 1, 0, 3, NULL, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2012-11-13', 4, 1, 2, NULL, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2012-11-13', 2, 2, 1, 4, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2012-12-13', 3, 3, 2, 5, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2010-11-13', 0, 0, 1, 4, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2009-11-13', 0, 2, 1, 5, DEFAULT);
INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), '2012-11-14', 5, 0, 1, 5, DEFAULT);

-- fill  comments
INSERT INTO amz_comments VALUES(1, 0, 4, '2012-12-13', 'Superbe produit. Dommage que le prix soit si important pour peu de contenu. J''encourage l''achat.');
INSERT INTO amz_comments VALUES(0, 1, 5, '2012-11-10', 'Ecran de tres bonne qualite. Tres bon produit.');
INSERT INTO amz_comments VALUES(1, 4, 3, '2012-12-11', 'Console qui commence a vieillir un peu. Peu de jeux disponibles pour le moment. Trop cher. Niveau graphismes, rien à dire.');
INSERT INTO amz_comments VALUES(3, 3, 4, '2012-12-11', 'Pack interessant avec disque dur avec stockage important. A essayer au moins une fois.');

-- fill payments
INSERT INTO amz_payments VALUES(0, '2012-11-17', 'BNP-PARIBAS', 133, 'EUR', 'rejected');
INSERT INTO amz_payments VALUES(1, '2012-11-15', 'CIC', 222, 'EUR', 'accepted');
INSERT INTO amz_payments VALUES(2, '2012-11-16', 'SOCIETE-GENERALE', 333, 'EUR', 'accepted');
INSERT INTO amz_payments VALUES(3, '2012-12-15', 'BNP-PARIBAS', 987, 'USD', 'accepted');
INSERT INTO amz_payments VALUES(4, '2010-11-15', 'BANK-OF-CHINA', 154, 'YEN', 'accepted');
INSERT INTO amz_payments VALUES(5, '2009-12-01', 'DEXIA', 187, 'EUR', 'accepted');
INSERT INTO amz_payments VALUES(6, '2012-11-22', 'CRED-AGRICOL', 132, 'EUR', 'rejected');


-- FREQUENT QUERIES


-- 1. base research of product in db (dimensions of pic are not important because of resizing)
-- get parameters :
	-- prod_cat_name
	-- prod_price
	-- prod_name
	-- prod_designer

SELECT prod_id, prod_stock, prod_name, prod_designer, prod_price, pic_url 
	FROM amz_products
	LEFT JOIN amz_pictures 
	ON prod_pic_url = pic_url 
	WHERE prod_cat_name = 'Informatique' 
	  AND prod_name LIKE '%Console%' 
	  --AND prod_designer LIKE '%IIYAMA%' 
	  AND prod_price::numeric >= 150.00 AND prod_price::numeric < 300.00
	  AND prod_stock > 0;




-- 2. log in of users
-- post parameters :
	-- cust_email
	-- cust_password

SELECT cust_id FROM amz_customers 
	WHERE cust_email = 'christophe.db@gmail.com' 
	  AND cust_password = SHA1('lol');



-- 3. get comments about a product
-- get paremeters :


SELECT com_grade AS note, substring(com_text from 0 for 20) AS commentaire, com_date AS date, 
	   cust_name AS nom_client, prod_name AS nom_pdt FROM amz_comments 
	LEFT JOIN amz_customers 
		ON com_cust_id = cust_id 
	LEFT JOIN amz_products 
		ON com_prod_id = prod_id 
	WHERE prod_cat_name = 'Informatique';




-- 4. add / remove item from customer basket
-- insert, delete from...
-- we cannot add a table to stock customer basket because of the complexity and the time to produce this work was a bit short !



-- INTERESTING VIEW

CREATE OR REPLACE VIEW interestedPayments AS 
	SELECT pay_ord_id, pay_status, pay_bank, pay_devise, prod_price, prod_name, cust_name FROM amz_payments 
		LEFT JOIN amz_orders
			ON pay_ord_id = ord_id
		LEFT JOIN amz_customers 
			ON ord_buyer_id = cust_id 
		LEFT JOIN amz_products 
			ON ord_product_id = prod_id 
		ORDER BY cust_name;
SELECT * FROM interestedPayments;




-- TRANSACTIONS (just an example)

-- if one of the empacted queries fails, then transaction will roll back
-- begin transaction
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ WRITE;
BEGIN;

	-- insert new order
	INSERT INTO amz_orders VALUES(nextval('amz_ordersSQ'), CURRENT_DATE, 1, 1, 4, NULL, DEFAULT);

	-- searching for product price
	SELECT prod_price FROM amz_products 
		LEFT JOIN amz_orders 
		ON ord_product_id = prod_id 
		WHERE prod_id = ord_product_id 
		LIMIT 1;

	-- new payment for previous order
	INSERT INTO amz_payments VALUES(currval('amz_ordersSQ'), CURRENT_DATE, 'BNP-PARIBAS', 123, 'EUR', DEFAULT);

	-- updating number of payments for this customer
	UPDATE amz_customers SET cust_nb_order = cust_nb_order + 1 
		WHERE cust_id = 1;

-- end of transaction
COMMIT;



-- drop triggers
DROP TRIGGER IF EXISTS considerPayment ON amz_payments CASCADE;
DROP TRIGGER IF EXISTS removePaymentOrder ON amz_payments CASCADE;
DROP TRIGGER IF EXISTS checkComment ON amz_comments CASCADE;



-- MEMO --

-- UNIQUE : champ indéxé + contrainte d'intégrité + NULL autorisé
-- INDEX : champ indéxé simple
-- PK : index + unique + pas de NULL



-- TO DO --

-- remplir (notamment orders et payments)
-- rediger rapport / ppt



-- pas de normalisation, pourquoi?
-- index et clé primaire, ou et pourquoi?
-- cluster, pourquoi?
-- 


