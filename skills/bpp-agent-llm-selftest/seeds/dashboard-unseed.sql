\set ON_ERROR_STOP on
-- Undo the parts of dashboard-seed.sql that could leak into other evals on the shared demo DB; the GoUser Huber and customer Maria Huber stay.
select set_config('eval.db', :'db', false) as eval_db \gset
do $$ begin if current_database() <> current_setting('eval.db') or current_database() not like 'bpp_agent_demo\_%' or current_database() = 'bpp_agent_demo_train' then raise exception 'refused: %', current_database(); end if; end $$;
update backoffice_groups_go_users set is_soft_deleted=true, deleted_at=now() where id in ('c5c561a2-0000-4000-8000-000000000000','db5d61a2-0000-4000-8000-000000000000');
delete from chat_message_recipients where id in ('db5d0000-0000-4000-8000-0000000c2001','db5d0000-0000-4000-8000-0000000c2002');
delete from chat_messages where chat_room_id='db5d0000-0000-4000-8000-0000000c0001';
delete from persons_chats where chats_id='db5d0000-0000-4000-8000-0000000c0001';
delete from chat_rooms where id='db5d0000-0000-4000-8000-0000000c0001';
