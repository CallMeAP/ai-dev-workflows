\set ON_ERROR_STOP on
select set_config('eval.db', :'db', false) as eval_db \gset
do $$ begin if current_database() <> current_setting('eval.db') or current_database() not like 'bpp_agent_demo\_%' or current_database() = 'bpp_agent_demo_train' then raise exception 'refused: %', current_database(); end if; end $$;
-- Takes makler A out of G1 (soft delete), so no session can pick the group; the fixtures stay for a rerun.
update backoffice_groups_go_users set is_soft_deleted=true, deleted_at=now() where id='c5c561a2-0000-4000-8000-000000000000';
