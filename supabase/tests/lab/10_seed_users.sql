-- os mesmos 5 usuários e permissões do projeto real (senha 1234)
with novos as (
  select gen_random_uuid() as id, u.usuario, u.usuario || '@painel.local' as email, u.nome
  from (values ('luiz','Luiz'),('victor','Victor'),('enzo','Enzo'),('rafael','Rafael'),('vinicius','Vinicius')) as u(usuario, nome)
), a as (
  insert into auth.users (id, email, encrypted_password) select id, email, crypt('1234', gen_salt('bf')) from novos returning id
), p as (
  insert into public.perfis (id, nome, papel) select id, nome, 'gerente' from novos returning id
)
insert into public.perfis_lojas (perfil_id, loja_id)
select n.id, l.id from novos n
join (values ('luiz','smoke-club'),('luiz','start-br01'),('luiz','ez-store'),('victor','smoke-club'),('victor','ez-store'),
             ('enzo','start-br01'),('rafael','streaks-store'),('vinicius','streaks-store')) c(usuario, slug) on c.usuario = n.usuario
join public.lojas l on l.slug = c.slug;
