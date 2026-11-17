# Generates the custscope fixtures (repo Fixtures/ProposalEval/custscope.json) for a demo DB. Ids in the c5c5 range, rows marked
# created_by_name 'Custscope Eval Seed'; synthetic people, example.invalid addresses. Template GoUser ...026 and tenant ...001 are the
# demo copy's seeded dev rows. Owner = makler_a = your developer GoUser.
# Usage: python3 -I custscope-gen.py <out.sql> <owner-go-user-id>; then (lib.sh) pgw -1 -v db=$DEMO_DB -f <out.sql>
import sys
A=sys.argv[2]
B='c5c50000-0000-4000-8000-00000000b000'   # eval.makler.b
BP='c5c50001-0000-4000-8000-00000000b000'  # its person
G1='c5c50000-0000-4000-8000-0000000061a1'
INS="(select id from insurance_companies order by created_at limit 1)"
N="'Custscope Eval Seed'"
out=[]
w=out.append
w(r"""\set ON_ERROR_STOP on
select set_config('eval.db', :'db', false) as eval_db \gset
do $$ begin if current_database() <> current_setting('eval.db') or current_database() not like 'bpp_agent_demo\_%' or current_database() = 'bpp_agent_demo_train' then raise exception 'refused: %', current_database(); end if; end $$;
""")
def q(v): return 'null' if v is None else "'"+str(v).replace("'","''")+"'"
def uid(kind,n): return f"c5c5{kind:04x}-0000-4000-8000-{n:012d}"
w(f"insert into persons (id, firstname, lastname, gender, brokernet_language_type, created_by_type, created_at, is_soft_deleted) values ({q(BP)},'Bernhard','Nordegger','male','de','system',now(),false) on conflict do nothing;")
w(f"""insert into go_users (id, username, login_email, password_hash, password_salt, is_default_login_password_set, broker_shortcode, user_go_funktion, user_unternehmens_funktion, tenant_id, person_id, created_by_name, created_by_type, created_at, is_soft_deleted)
 select {q(B)}, 'eval.makler.b', 'eval.makler.b@example.invalid', t.password_hash, t.password_salt, true, '900-cs1', t.user_go_funktion, 'makler', t.tenant_id, {q(BP)}, {N}, 'system', now(), false from go_users t where t.id='defa0000-0000-0000-0000-000000000026' on conflict do nothing;""")
w(f"insert into backoffice_groups (id, group_name, tenant_id, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(G1)}, 'Team Eval Nord', 'defa0000-0000-0000-0000-000000000001', {N}, 'system', now(), false) on conflict do nothing;")
for i,(u) in enumerate([A,B]):
    m=uid(0x61a2,i)
    w(f"insert into backoffice_groups_go_users (id, backoffice_group_id, go_user_id, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(m)},{q(G1)},{q(u)},{N},'system',now(),false) on conflict (id) do update set is_soft_deleted=false, deleted_at=null;")
    for j,p in enumerate(['can_write_claims','can_write_contracts','can_write_customers']):
        w(f"insert into backoffice_group_go_user_permissions (id, backoffice_group_go_user_permission, backoffice_group_go_user_id, created_by_type, created_at, is_soft_deleted) values ({q(uid(0x61a3,i*10+j))},{q(p)},{q(m)},'system',now(),false) on conflict do nothing;")

def private(n, owner, first, last, gender, birth, email=None, phone=None, city='Wien', zip='1100'):
    c,p=uid(0,n),uid(1,n)
    w(f"insert into customers (id, customer_type, go_user_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(c)},'private_customer',{q(owner)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    w(f"insert into private_customers (id) values ({q(c)}) on conflict do nothing;")
    w(f"insert into persons (id, firstname, lastname, birthdate, gender, brokernet_language_type, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(p)},{q(first)},{q(last)},{q(birth)},{q(gender)},'de',{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    w(f"insert into customer_persons (id, customer_person_relation_type, is_main_ansprechpartner, person_id, customer_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(2,n))},'is_self',true,{q(p)},{q(c)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    if email or phone:
        w(f"insert into contact_infos (id, email, phone, is_default_contact_info, person_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(3,n))},{q(email)},{q(phone)},true,{q(p)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    w(f"insert into addresses (id, street, house_number, zip, city, bundesland, country, is_default_address, person_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(4,n))},'Evalgasse',{q(str(n%97+1))},{q(zip)},{q(city)},'wien','austria',true,{q(p)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    return c
def company(n, owner, name, rf, main_first, main_last):
    c,p=uid(0,n),uid(1,n)
    w(f"insert into customers (id, customer_type, go_user_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(c)},'company_customer',{q(owner)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    w(f"insert into company_customers (id, company_name, rechtsform, is_share_holder, bilanzstichtag, bilanzstichtag_monat) values ({q(c)},{q(name)},{q(rf)},false,31,12) on conflict do nothing;")
    w(f"insert into persons (id, firstname, lastname, gender, brokernet_language_type, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(p)},{q(main_first)},{q(main_last)},'male','de',{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    w(f"insert into customer_persons (id, customer_person_relation_type, is_main_ansprechpartner, person_id, customer_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(2,n))},'ceo',true,{q(p)},{q(c)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    return c
def contract(n, cust, owner, pol, product='Haushaltsversicherung'):
    k=uid(5,n)
    w(f"insert into contracts (id, contract_product_type, brokernet_product_type, brokernet_product_name, product_name, contract_status, contract_bearbeitungs_status, contract_begin_at, polizze_number, versicherungspraemie_brutto_in_eur, insurance_company_id, customer_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(k)},'sachversicherung','fremdvertrag','vera',{q(product)},'aktiv','abgeschlossen','2024-01-01T00:00:00+01',{q(pol)},180,{INS},{q(cust)},{q(owner)},{N},'user',now(),false) on conflict do nothing;")
    return k

# Makler A (the owner)
h=private(4001,A,'Erika','Hochkogler','female','1979-03-14','e.hochkogler@example.invalid','0664/5550123')
w(f"""insert into third_party_sync_links (id, third_party_id, third_party_sync_link_type, original_response_json, customer_id, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(6,4001))},'EVAL-OID-C5C54001','vera','{{"customerNumber":"EVAL-CS-4001"}}',{q(h)},{N},'system',now(),false) on conflict do nothing;""")
m=private(4002,A,'Johann','Müller','male','1961-06-02','j.mueller.cs@example.invalid','0660/5550202',city='Graz',zip='8010')
contract(4101,m,A,'POL-CS-4101','KFZ-Haftpflicht')
s=private(4003,A,'Theresia','Strauß','female','1958-11-23','t.strauss.cs@example.invalid','0676/5550303',city='Linz',zip='4020')
k=contract(4301,s,A,'POL-CS-4301')
w(f"insert into claims (id, claim_number, claim_status, claim_start, schadenshergang, ist_behoerdlich_aufgenommen, contract_id, claim_type, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(7,4201))},'SCH-CS-4201','ausstehend','2026-10-02T00:00:00+02','Sturmschaden am Dach.',false,{q(k)},'sonstiges',{q(A)},{N},'user',now(),false) on conflict do nothing;")
private(4004,A,'Franz','Weninger','male','1970-01-15','f.weninger@example.invalid',None,city='St. Pölten',zip='3100')
private(4005,A,'Stefan','Weninger','male','1988-08-30','s.weninger@example.invalid',None,city='Krems',zip='3500')
pb=company(4006,A,'Pichler Bau GmbH','gesellschaft_mit_beschraenkter_haftung','Herbert','Pichler')
w(f"insert into persons (id, firstname, lastname, gender, brokernet_language_type, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(1,4016))},'Andrea','Reisinger','female','de',{q(A)},{N},'user',now(),false) on conflict do nothing;")
w(f"insert into customer_persons (id, customer_person_relation_type, is_main_ansprechpartner, person_id, customer_id, created_by, created_by_name, created_by_type, created_at, is_soft_deleted) values ({q(uid(2,4016))},'ansprechperson',false,{q(uid(1,4016))},{q(pb)},{q(A)},{N},'user',now(),false) on conflict do nothing;")
company(4007,A,'Seewirt Gastro OG','offene_gesellschaft','Martin','Seewirt')
private(4008,A,'Brigitte','Berger','female','1990-04-04','b.berger.cs@example.invalid',None)
# Makler B
private(4101+5000,B,'Gerold','Fuchsbichler','male','1966-02-19','g.fuchsbichler@example.invalid','0650/5550909',city='Salzburg',zip='5020')
private(4102+5000,B,'Erika','Hochkogler','female','1985-09-02','erika.h.cs@example.invalid','0699/5550404',city='Innsbruck',zip='6020')
company(4103+5000,B,'Nordlicht Handels GmbH','gesellschaft_mit_beschraenkter_haftung','Paul','Nordlicht')
sur=['Bauer','Berger','Binder','Brunner','Bichler','Baumgartner','Buchner','Böhm','Brandstätter','Burger','Bergmann','Bacher','Brandl','Blaschke','Breitenberger']
fir=['Anna','Bernd','Clara','David','Eva','Florian','Gabi','Hans','Ida','Jakob','Klara','Lukas','Martina','Norbert','Olga','Peter','Rita','Simon','Tanja','Udo','Vera','Walter','Xaver']
for i in range(115):
    private(4200+i+5000,B,fir[i%len(fir)],sur[i%len(sur)],'female' if i%2 else 'male',f"19{50+i%45}-0{1+i%9}-1{i%9}")
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
