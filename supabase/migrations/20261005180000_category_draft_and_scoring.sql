-- Additive category draft and pick-bonus scoring migration.
alter table public.movie_nights drop constraint if exists movie_nights_phase_check;
alter table public.movie_nights add constraint movie_nights_phase_check
  check (phase in ('category_draft','nominations','leaderboard','complete'));
alter table public.night_members add column if not exists pick_position integer;
alter table public.night_participants alter column category_id drop not null;
alter table public.night_participants add column if not exists selected_at timestamptz;

-- Preserve a stable order for existing nights; newly started nights receive a randomized order once.
with positioned as (
  select night_id,user_id,row_number() over(partition by night_id order by joined_at,user_id)::integer as pick_position
  from public.night_members where pick_position is null
)
update public.night_members nm set pick_position=p.pick_position
from positioned p where p.night_id=nm.night_id and p.user_id=nm.user_id;
alter table public.night_members alter column pick_position set not null;
create unique index if not exists night_members_pick_position_uidx
  on public.night_members(night_id,pick_position);
update public.night_participants set selected_at=now()
where category_id is not null and selected_at is null;

create or replace function public.start_movie_night()
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid := gen_random_uuid();
  v_participant_count integer;
  v_category_count integer;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(73104811223::bigint);
  if exists(select 1 from public.movie_nights where phase <> 'complete') then
    raise exception 'Concludi la serata attiva prima di crearne una nuova.';
  end if;
  select count(*) into v_participant_count from public.profiles;
  select count(*) into v_category_count from public.film_categories;
  if v_participant_count=0 then raise exception 'Nessun partecipante attivo.'; end if;
  if v_participant_count>v_category_count then
    raise exception 'Servono almeno tante categorie quanti sono i partecipanti.';
  end if;
  insert into public.movie_nights(id,created_by,phase)
  values(v_night_id,auth.uid(),'category_draft');
  with randomized_order as (
    select p.id,row_number() over(order by random(),p.id)::integer as pick_position
    from public.profiles p
  )
  insert into public.night_members(night_id,user_id,pick_position)
  select v_night_id,id,pick_position from randomized_order;
  insert into public.night_participants(night_id,user_id,category_id)
  select v_night_id,user_id,null from public.night_members where night_id=v_night_id;
  return v_night_id;
end;
$$;

create or replace function public.get_category_draft_state(p_night_id uuid)
returns table(
  pick_position integer,user_id uuid,username text,category_id integer,category_name text,
  picked_at timestamptz,pick_bonus numeric,is_current_turn boolean,is_me boolean
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_participant_count integer;
  v_current_user uuid;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select count(*) into v_participant_count from public.night_members nm where nm.night_id=p_night_id;
  select nm.user_id into v_current_user
  from public.night_members nm
  join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  where nm.night_id=p_night_id and np.category_id is null
  order by nm.pick_position limit 1;
  return query
  select nm.pick_position,nm.user_id,p.username,np.category_id,c.name,np.selected_at,
    case when v_participant_count<=1 then 0::numeric
      else 0.5::numeric*(nm.pick_position-1)::numeric/(v_participant_count-1)::numeric end,
    nm.user_id=v_current_user,nm.user_id=auth.uid()
  from public.night_members nm
  join public.profiles p on p.id=nm.user_id
  left join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  left join public.film_categories c on c.id=np.category_id
  where nm.night_id=p_night_id
  order by nm.pick_position;
end;
$$;

create or replace function public.select_draft_category(p_night_id uuid,p_category_id integer)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_current_user uuid;
begin
  if auth.uid() is null then raise exception 'Accedi per scegliere una categoria.'; end if;
  select n.phase into v_phase from public.movie_nights n where n.id=p_night_id for update;
  if v_phase is distinct from 'category_draft' then raise exception 'La scelta delle categorie è terminata.'; end if;
  select nm.user_id into v_current_user
  from public.night_members nm
  join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  where nm.night_id=p_night_id and np.category_id is null
  order by nm.pick_position limit 1;
  if v_current_user is null then raise exception 'Tutte le categorie sono già state scelte.'; end if;
  if v_current_user<>auth.uid() then raise exception 'Non è il tuo turno di scegliere una categoria.'; end if;
  if not exists(select 1 from public.film_categories c where c.id=p_category_id) then
    raise exception 'Categoria non disponibile.';
  end if;
  if exists(select 1 from public.night_participants np
    where np.night_id=p_night_id and np.category_id=p_category_id) then
    raise exception 'Questa categoria è già stata scelta.';
  end if;
  update public.night_participants np set category_id=p_category_id,selected_at=now()
  where np.night_id=p_night_id and np.user_id=auth.uid() and np.category_id is null;
  if not found then raise exception 'Hai già scelto una categoria.'; end if;
  if not exists(select 1 from public.night_participants np
    where np.night_id=p_night_id and np.category_id is null) then
    update public.movie_nights set phase='nominations' where id=p_night_id;
  end if;
end;
$$;

create or replace function public.cast_movie_rating(p_drawn_film_id uuid,p_rating numeric)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_status text;
  v_phase text;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_rating is null or p_rating<1 or p_rating>5 or p_rating*2<>trunc(p_rating*2) then
    raise exception 'Il voto deve essere da 1 a 5, con incrementi di mezzo popcorn.';
  end if;
  select d.night_id,d.status into v_night_id,v_status
  from public.drawn_films d where d.id=p_drawn_film_id for update;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_status<>'approved' then raise exception 'Il film non è stato approvato.'; end if;
  select n.phase into v_phase from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'La classifica è già stata finalizzata.';
  end if;
  -- The composite primary key keeps one row per participant and film; upsert preserves own-rating edits.
  insert into public.movie_ratings(drawn_film_id,user_id,rating)
  values(p_drawn_film_id,auth.uid(),p_rating)
  on conflict(drawn_film_id,user_id) do update set rating=excluded.rating,rated_at=now();
  update public.drawn_films d set rating_count=(
    select count(*) from public.movie_ratings r where r.drawn_film_id=p_drawn_film_id
  ) where d.id=p_drawn_film_id;
end;
$$;

create or replace function public.finalize_movie_night(p_night_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_revealed integer;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select n.phase into v_phase from public.movie_nights n where n.id=p_night_id for update;
  if v_phase is null or v_phase not in ('nominations','leaderboard') then
    raise exception 'La serata non è pronta per essere finalizzata.';
  end if;
  if exists(select 1 from public.night_members nm
    where nm.night_id=p_night_id and not nm.has_nominated)
    or exists(select 1 from public.movie_nominations n
      where n.night_id=p_night_id and n.status='queued') then
    raise exception 'Estrai prima tutte le nomination.';
  end if;
  if exists(select 1 from public.drawn_films d
    where d.night_id=p_night_id and d.status<>'approved') then
    raise exception 'Completa la verifica dei film prima di finalizzare.';
  end if;
  select count(*) into v_revealed from public.drawn_films d
    where d.night_id=p_night_id and d.status='approved';
  update public.movie_nights set phase='complete',revealed_count=v_revealed,finished_at=now()
  where id=p_night_id;
end;
$$;

create or replace function public.get_leaderboard_state(p_night_id uuid)
returns table(unlocked boolean,total_films integer,revealed integer,phase text)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_phase text;
  v_total integer;
  v_revealed integer;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select n.phase,n.revealed_count into v_phase,v_revealed
    from public.movie_nights n where n.id=p_night_id;
  if v_phase is null then raise exception 'Serata non trovata.'; end if;
  select count(*) into v_total from public.drawn_films d
    where d.night_id=p_night_id and d.status='approved';
  return query select v_phase='complete',v_total,case when v_phase='complete' then v_total else v_revealed end,v_phase;
end;
$$;

create or replace function public.calculate_night_film_scores(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language sql stable security definer set search_path=''
as $$
  with participant_totals as (
    select count(*)::integer as participant_count from public.night_members nm where nm.night_id=p_night_id
  ), film_averages as (
    select d.id,d.title,c.name as category_name,selector.username as selected_by,
      selector_order.pick_position,count(r.user_id)::bigint as rating_count,avg(r.rating)::numeric as average_rating,
      case when pt.participant_count<=1 then 0::numeric
        else 0.5::numeric*(selector_order.pick_position-1)::numeric/(pt.participant_count-1)::numeric end as pick_bonus,
      m.poster_url
    from public.drawn_films d
    join public.film_categories c on c.id=d.category_id
    cross join participant_totals pt
    left join lateral (
      select nm.user_id,nm.pick_position from public.night_participants np
      join public.night_members nm on nm.night_id=np.night_id and nm.user_id=np.user_id
      where np.night_id=d.night_id and np.category_id=d.category_id
      order by nm.pick_position limit 1
    ) selector_order on true
    left join public.profiles selector on selector.id=selector_order.user_id
    left join public.drawn_film_metadata m on m.drawn_film_id=d.id
    left join public.movie_ratings r on r.drawn_film_id=d.id
    where d.night_id=p_night_id and d.status='approved'
    group by d.id,d.title,c.name,selector.username,selector_order.pick_position,pt.participant_count,m.poster_url
  ), film_scores as (
    select f.*,case when f.average_rating is null then null
      else least(5::numeric,f.average_rating+f.pick_bonus) end as raw_final_score
    from film_averages f
  ), ranked as (
    select s.*,case when s.raw_final_score is null then null::integer
      else rank() over(order by s.raw_final_score desc nulls last,s.average_rating desc nulls last)::integer end as raw_rank
    from film_scores s
  )
  select r.id,r.title,r.category_name,r.selected_by,r.pick_position,r.rating_count,
    round(r.average_rating,2),round(r.pick_bonus,2),round(r.raw_final_score,2),r.raw_rank,r.poster_url
  from ranked r
  order by r.raw_final_score desc nulls last,r.average_rating desc nulls last,r.title asc;
$$;

create or replace function public.get_provisional_leaderboard(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  if not exists(select 1 from public.movie_nights n where n.id=p_night_id and n.phase<>'complete') then
    raise exception 'La classifica provvisoria non è disponibile.';
  end if;
  return query select s.* from public.calculate_night_film_scores(p_night_id) s;
end;
$$;

drop function if exists public.get_revealed_movies(uuid);
create function public.get_revealed_movies(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  if not exists(select 1 from public.movie_nights n where n.id=p_night_id and n.phase='complete') then
    raise exception 'La classifica finale non è ancora stata pubblicata.';
  end if;
  return query select s.* from public.calculate_night_film_scores(p_night_id) s;
end;
$$;

-- The category picker sees the shared draft state through an RPC; raw private assignments stay inaccessible.
revoke all on function public.calculate_night_film_scores(uuid) from public,anon,authenticated;
revoke all on function public.get_category_draft_state(uuid) from public,anon,authenticated;
revoke all on function public.select_draft_category(uuid,integer) from public,anon,authenticated;
revoke all on function public.finalize_movie_night(uuid) from public,anon,authenticated;
revoke all on function public.get_provisional_leaderboard(uuid) from public,anon,authenticated;
revoke all on function public.admin_reveal_next_rank(uuid) from public,anon,authenticated;
grant execute on function public.get_category_draft_state(uuid) to authenticated;
grant execute on function public.select_draft_category(uuid,integer) to authenticated;
grant execute on function public.finalize_movie_night(uuid) to authenticated;
grant execute on function public.get_provisional_leaderboard(uuid) to authenticated;
grant execute on function public.get_revealed_movies(uuid) to authenticated;
