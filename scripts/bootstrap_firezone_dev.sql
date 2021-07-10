-- Execute this with your DB admin user
create role firezone;
alter role firezone with password 'postgres';
alter role firezone with login;
alter role firezone with superuser;
