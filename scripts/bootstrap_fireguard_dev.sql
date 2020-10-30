-- Execute this with your DB admin user
create role fireguard;
alter role fireguard with password 'postgres';
alter role firegurd with login;
alter role fireguard with superuser;
