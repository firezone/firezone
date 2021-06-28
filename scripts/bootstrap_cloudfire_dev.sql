-- Execute this with your DB admin user
create role cloudfire;
alter role cloudfire with password 'postgres';
alter role cloudfire with login;
alter role cloudfire with superuser;
