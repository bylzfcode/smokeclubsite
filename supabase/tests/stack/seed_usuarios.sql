-- Usuários de teste criados por SQL direto em auth.users/auth.identities (o mesmo método usado no projeto remoto), senha 1234.
-- 'carla' = operador da Smoke Club (para provar o que operador NÃO pode fazer na mesma loja).
-- 'chefe' = papel dono, vinculado só à Start BR01 (para provar que o dono enxerga as outras lojas mesmo sem vínculo).
with novos as (
  select gen_random_uuid() as id, u.usuario, u.usuario || '@painel.local' as email, u.nome, u.papel
  from (values ('luiz','Luiz','gerente'),('victor','Victor','gerente'),('enzo','Enzo','operador'),('rafael','Rafael','gerente'),('vinicius','Vinicius','operador'),('chefe','Chefe','dono'),('carla','Carla','operador')) as u(usuario, nome, papel)
), a as (
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, extensions.crypt('1234', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '' from novos returning id, email
), i as (
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select a.id::text, a.id, jsonb_build_object('sub', a.id::text, 'email', a.email, 'email_verified', true), 'email', now(), now(), now() from a returning user_id
), p as (
  insert into public.perfis (id, nome, papel) select id, nome, papel from novos returning id
)
insert into public.perfis_lojas (perfil_id, loja_id)
select n.id, l.id from novos n
join (values ('luiz','smoke-club'),('luiz','start-br01'),('luiz','ez-store'),('victor','smoke-club'),('victor','ez-store'),
             ('enzo','start-br01'),('rafael','streaks-store'),('vinicius','streaks-store'),('chefe','start-br01'),('carla','smoke-club')) c(usuario, slug) on c.usuario = n.usuario
join public.lojas l on l.slug = c.slug;
