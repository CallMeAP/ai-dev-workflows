-- Ground truth for the custscope numbers, read-only, at the time of the call. Usage: pgr -v owner=<go-user-id> -Atf custscope-truth.sql
set default_transaction_read_only = on;
with a as (select :'owner'::uuid id),
g1 as (select bgu.go_user_id id from backoffice_groups_go_users bgu join go_users g on g.id=bgu.go_user_id
       where bgu.backoffice_group_id='c5c50000-0000-4000-8000-0000000061a1' and not bgu.is_soft_deleted and g.user_unternehmens_funktion in ('makler','geschaeftsfuehrer')),
c as (select c.*, coalesce(cc.company_name, p.lastname) nm from customers c left join company_customers cc on cc.id=c.id
      left join customer_persons cp on cp.customer_id=c.id and cp.is_main_ansprechpartner and not cp.is_soft_deleted left join persons p on p.id=cp.person_id
      where not c.is_soft_deleted)
select json_build_object('at', now(),
 'own_total', (select count(*) from c where go_user_id=(select id from a)),
 'own_private', (select count(*) from c where go_user_id=(select id from a) and customer_type='private_customer'),
 'own_company', (select count(*) from c where go_user_id=(select id from a) and customer_type='company_customer'),
 'g1_total', (select count(*) from c where go_user_id in (select id from g1)),
 'g1_company', (select count(*) from c where go_user_id in (select id from g1) and customer_type='company_customer'),
 'own_b', (select count(*) from c where go_user_id=(select id from a) and nm ilike 'B%'),
 'g1_b', (select count(*) from c where go_user_id in (select id from g1) and nm ilike 'B%'),
 'makler_of_fuchsbichler', 'Bernhard Nordegger');
