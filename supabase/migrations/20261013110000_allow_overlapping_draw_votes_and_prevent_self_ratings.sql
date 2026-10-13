-- Let the organizer draw the next movie while an earlier movie is still
-- waiting for ratings or its seen/unseen ballot. Ratings remain open in Voti
-- until the organizer finalizes the night. A nomination owner cannot rate
-- their own movie; legacy self-ratings are excluded from counts and scores.

update public.drawn_films d set rating_count=(
  select count(*)::integer
  from public.movie_ratings r
  join public.movie_nominations n on n.id=d.nomination_id
  where r.drawn_film_id=d.id and r.user_id is distinct from n.user_id
);

create or replace function public.admin_draw_next(p_night_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_nomination record;
  v_film_id uuid := gen_random_uuid();
  v_member_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_status text;
  v_decided_at timestamptz;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select phase into v_phase from public.movie_nights where id=p_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'La fase nomination è terminata.'; end if;
  if exists(select 1 from public.night_members where night_id=p_night_id and not has_nominated) then
    raise exception 'Attendi che tutti inviino una nomination.';
  end if;
  if exists(select 1 from public.movie_nominations n
    where n.night_id=p_night_id and n.status='queued'
      and (select count(*) filter(where nsv.has_seen)
        from public.nomination_seen_votes nsv
        join public.night_members nm on nm.night_id=p_night_id and nm.user_id=nsv.user_id
        where nsv.nomination_id=n.id)*100
        > (select count(*) from public.night_members where night_id=p_night_id)*55) then
    raise exception 'Chi ha proposto una nomination già vista deve sostituirla prima del sorteggio.';
  end if;
  if exists(select 1 from public.drawn_films where night_id=p_night_id and status='rejected') then
    raise exception 'Il responsabile della nomination deve sostituire il titolo rifiutato.';
  end if;
  select n.id,n.title,n.category_id into v_nomination
  from public.movie_nominations n
  where n.night_id=p_night_id and n.status='queued'
  order by random() limit 1 for update skip locked;
  if v_nomination.id is null then raise exception 'Il pool delle nomination è vuoto.'; end if;
  select count(*)::integer into v_member_count
  from public.night_members where night_id=p_night_id;
  select count(*)::integer,count(*) filter(where nsv.has_seen)::integer
    into v_vote_count,v_seen_count
  from public.nomination_seen_votes nsv where nsv.nomination_id=v_nomination.id;
  if v_vote_count=v_member_count then
    v_status := case when v_seen_count*100 > v_member_count*55 then 'rejected' else 'approved' end;
    v_decided_at := now();
  else
    v_status := 'checking';
    v_decided_at := null;
  end if;
  update public.movie_nominations set status='drawn' where id=v_nomination.id;
  insert into public.drawn_films(
    id,night_id,nomination_id,title,category_id,status,member_count,vote_count,seen_count,decided_at
  ) values (
    v_film_id,p_night_id,v_nomination.id,v_nomination.title,v_nomination.category_id,
    v_status,v_member_count,v_vote_count,v_seen_count,v_decided_at
  );
  insert into public.seen_votes(drawn_film_id,user_id,has_seen,voted_at)
  select v_film_id,nsv.user_id,nsv.has_seen,nsv.voted_at
  from public.nomination_seen_votes nsv where nsv.nomination_id=v_nomination.id
  on conflict(drawn_film_id,user_id) do update
    set has_seen=excluded.has_seen,voted_at=excluded.voted_at;
  return v_film_id;
end;
$$;

create or replace function public.cast_movie_rating(p_drawn_film_id uuid,p_rating numeric)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_status text;
  v_phase text;
  v_owner_id uuid;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_rating is null or p_rating<1 or p_rating>5 or p_rating*2<>trunc(p_rating*2) then
    raise exception 'Il voto deve essere da 1 a 5, con incrementi di mezzo popcorn.';
  end if;
  select d.night_id,d.status,n.user_id into v_night_id,v_status,v_owner_id
  from public.drawn_films d
  join public.movie_nominations n on n.id=d.nomination_id
  where d.id=p_drawn_film_id for update of d;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if auth.uid()=v_owner_id then
    raise exception 'Non puoi votare un film che hai proposto.';
  end if;
  if v_status not in ('checking','approved') then raise exception 'Il film non è disponibile per le valutazioni.'; end if;
  select n.phase into v_phase from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'La classifica è già stata finalizzata.';
  end if;
  insert into public.movie_ratings(drawn_film_id,user_id,rating)
  values(p_drawn_film_id,auth.uid(),p_rating)
  on conflict(drawn_film_id,user_id) do update set rating=excluded.rating,rated_at=now();
  update public.drawn_films d set rating_count=(
    select count(*)::integer from public.movie_ratings r
    where r.drawn_film_id=p_drawn_film_id and r.user_id is distinct from v_owner_id
  ) where d.id=p_drawn_film_id;
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
    join public.movie_nominations n on n.id=d.nomination_id
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
    left join public.movie_ratings r
      on r.drawn_film_id=d.id and r.user_id is distinct from n.user_id
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

create or replace function public.get_nomination_vote_details(p_nomination_id uuid)
returns table(
  username text,has_seen boolean,seen_voted_at timestamptz,rating numeric,rated_at timestamptz
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_phase text;
begin
  if auth.uid() is null then raise exception 'Accedi per visualizzare i voti.'; end if;
  select n.night_id,mn.phase into v_night_id,v_phase
  from public.movie_nominations n
  join public.movie_nights mn on mn.id=n.night_id
  where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_phase is distinct from 'complete' then
    raise exception 'I voti individuali saranno visibili dopo la pubblicazione della classifica.';
  end if;
  return query
    select p.username,nsv.has_seen,nsv.voted_at,mr.rating,mr.rated_at
    from public.night_members nm
    join public.profiles p on p.id=nm.user_id
    left join public.nomination_seen_votes nsv
      on nsv.nomination_id=p_nomination_id and nsv.user_id=nm.user_id
    left join public.drawn_films d on d.nomination_id=p_nomination_id
    left join public.movie_ratings mr
      on mr.drawn_film_id=d.id and mr.user_id=nm.user_id and nm.user_id is distinct from (
        select n.user_id from public.movie_nominations n where n.id=p_nomination_id
      )
    where nm.night_id=v_night_id
    order by lower(p.username),p.username;
end;
$$;

revoke all on function public.admin_draw_next(uuid) from public,anon,authenticated;
revoke all on function public.cast_movie_rating(uuid,numeric) from public,anon,authenticated;
revoke all on function public.calculate_night_film_scores(uuid) from public,anon,authenticated;
revoke all on function public.get_nomination_vote_details(uuid) from public,anon,authenticated;
grant execute on function public.admin_draw_next(uuid) to authenticated;
grant execute on function public.cast_movie_rating(uuid,numeric) to authenticated;
grant execute on function public.get_nomination_vote_details(uuid) to authenticated;

-- The submitter is excluded from both ballots for their own nomination. Rebuild
-- existing seen-vote totals using only eligible members before replacing RPCs.
with vote_totals as (
  select d.id,
    (select count(*)::integer from public.night_members nm
      where nm.night_id=d.night_id and nm.user_id is distinct from n.user_id) as eligible_count,
    (select count(*)::integer from public.nomination_seen_votes nsv
      join public.night_members nm on nm.night_id=d.night_id and nm.user_id=nsv.user_id
      where nsv.nomination_id=n.id and nm.user_id is distinct from n.user_id) as vote_count,
    (select count(*)::integer from public.nomination_seen_votes nsv
      join public.night_members nm on nm.night_id=d.night_id and nm.user_id=nsv.user_id
      where nsv.nomination_id=n.id and nm.user_id is distinct from n.user_id and nsv.has_seen) as seen_count
  from public.drawn_films d
  join public.movie_nominations n on n.id=d.nomination_id
)
update public.drawn_films d set
  vote_count=totals.vote_count,
  seen_count=totals.seen_count,
  status=case when totals.vote_count=totals.eligible_count
    then case when totals.seen_count*100>totals.eligible_count*55 then 'rejected' else 'approved' end
    else 'checking' end,
  decided_at=case when totals.vote_count=totals.eligible_count then coalesce(d.decided_at,now()) else null end
from vote_totals totals where totals.id=d.id;

delete from public.movie_ratings r using public.drawn_films d
where r.drawn_film_id=d.id and d.status='rejected';
update public.drawn_films d set rating_count=(
  select count(*)::integer from public.movie_ratings r
  join public.movie_nominations n on n.id=d.nomination_id
  where r.drawn_film_id=d.id and r.user_id is distinct from n.user_id
);

create or replace function public.get_night_nomination_list(p_night_id uuid)
returns table(
  id uuid,user_id uuid,title text,status text,vote_count integer,seen_count integer,
  member_count integer,my_has_seen boolean
)
language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  return query
    select n.id,n.user_id,n.title,n.status,
      coalesce(v.vote_count,0)::integer,coalesce(v.seen_count,0)::integer,
      coalesce(v.member_count,0)::integer,v.my_has_seen
    from public.movie_nominations n
    left join lateral (
      select count(nm.user_id)::integer as member_count,
        count(nsv.user_id)::integer as vote_count,
        count(nsv.user_id) filter(where nsv.has_seen)::integer as seen_count,
        bool_or(nsv.has_seen) filter(where nm.user_id=auth.uid()) as my_has_seen
      from public.night_members nm
      left join public.nomination_seen_votes nsv
        on nsv.nomination_id=n.id and nsv.user_id=nm.user_id
      where nm.night_id=p_night_id and nm.user_id is distinct from n.user_id
    ) v on true
    where n.night_id=p_night_id
    order by n.created_at,n.id;
end;
$$;

create or replace function public.submit_nomination_seen_vote(p_nomination_id uuid,p_has_seen boolean)
returns text language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_owner_id uuid;
  v_phase text;
  v_member_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_drawn_film_id uuid;
  v_drawn_status text;
  v_next_status text;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_has_seen is null then raise exception 'Scegli se hai già visto il film.'; end if;
  select n.night_id,n.user_id into v_night_id,v_owner_id
  from public.movie_nominations n where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if auth.uid()=v_owner_id then raise exception 'Non puoi votare la nomination che hai inviato.'; end if;
  select n.phase into v_phase
  from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'Il periodo per modificare il voto è terminato.';
  end if;
  perform 1 from public.movie_nominations n
  where n.id=p_nomination_id and n.night_id=v_night_id for update;
  if not found then raise exception 'Nomination non disponibile.'; end if;
  select count(*)::integer into v_member_count
  from public.night_members nm
  where nm.night_id=v_night_id and nm.user_id is distinct from v_owner_id;
  insert into public.nomination_seen_votes(nomination_id,user_id,has_seen)
  values(p_nomination_id,auth.uid(),p_has_seen)
  on conflict(nomination_id,user_id)
  do update set has_seen=excluded.has_seen,voted_at=now();
  select count(*)::integer,count(*) filter(where nsv.has_seen)::integer
    into v_vote_count,v_seen_count
  from public.nomination_seen_votes nsv
  join public.night_members nm on nm.night_id=v_night_id and nm.user_id=nsv.user_id
  where nsv.nomination_id=p_nomination_id and nm.user_id is distinct from v_owner_id;

  select d.id,d.status into v_drawn_film_id,v_drawn_status
  from public.drawn_films d where d.nomination_id=p_nomination_id for update;
  if v_drawn_film_id is null then return 'queued'; end if;
  insert into public.seen_votes(drawn_film_id,user_id,has_seen,voted_at)
  values(v_drawn_film_id,auth.uid(),p_has_seen,now())
  on conflict(drawn_film_id,user_id)
  do update set has_seen=excluded.has_seen,voted_at=now();

  if v_vote_count=v_member_count then
    v_next_status := case when v_seen_count*100>v_member_count*55 then 'rejected' else 'approved' end;
    if v_next_status='rejected' and v_drawn_status='approved' then
      delete from public.movie_ratings where drawn_film_id=v_drawn_film_id;
      update public.drawn_films set rating_count=0 where id=v_drawn_film_id;
    end if;
    update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
      status=v_next_status,decided_at=now()
    where id=v_drawn_film_id;
    return v_next_status;
  end if;
  update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
    status='checking',decided_at=null
  where id=v_drawn_film_id;
  return 'checking';
end;
$$;

create or replace function public.replace_nomination_after_seen_vote(
  p_nomination_id uuid,p_title text,p_omdb_id text
)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_owner_id uuid;
  v_current_normalized text;
  v_phase text;
  v_member_count integer;
  v_seen_count integer;
  v_drawn_film_id uuid;
  v_title text := trim(coalesce(p_title,''));
  v_normalized text;
begin
  if auth.uid() is null then raise exception 'Accedi per sostituire la nomination.'; end if;
  if char_length(v_title)<2 or char_length(v_title)>140 then
    raise exception 'Inserisci un titolo tra 2 e 140 caratteri.';
  end if;
  select n.night_id into v_night_id from public.movie_nominations n where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Nomination o serata non disponibili.';
  end if;
  select mn.phase into v_phase from public.movie_nights mn where mn.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'Le sostituzioni sono chiuse per questa serata.';
  end if;
  select n.user_id,n.normalized_title into v_owner_id,v_current_normalized
  from public.movie_nominations n where n.id=p_nomination_id and n.night_id=v_night_id for update;
  if not found then raise exception 'Nomination non disponibile.'; end if;
  if v_owner_id is distinct from auth.uid() then
    raise exception 'Solo chi ha inviato la nomination può sostituirla.';
  end if;
  select count(*)::integer into v_member_count from public.night_members nm
  where nm.night_id=v_night_id and nm.user_id is distinct from v_owner_id;
  select count(*) filter(where nsv.has_seen)::integer into v_seen_count
  from public.nomination_seen_votes nsv
  join public.night_members nm on nm.night_id=v_night_id and nm.user_id=nsv.user_id
  where nsv.nomination_id=p_nomination_id and nm.user_id is distinct from v_owner_id;
  if v_member_count=0 or v_seen_count*100<=v_member_count*55 then
    raise exception 'La sostituzione è disponibile solo quando più del 55%% dei votanti ha già visto il film.';
  end if;
  v_normalized := lower(regexp_replace(v_title,'\s+',' ','g'));
  if v_normalized=v_current_normalized then raise exception 'Scegli un titolo diverso dalla nomination attuale.'; end if;
  begin
    update public.movie_nominations set title=v_title,normalized_title=v_normalized,
      omdb_id=nullif(trim(p_omdb_id),'') where id=p_nomination_id;
  exception when unique_violation then
    raise exception 'Questo titolo è già stato nominato nella serata.';
  end;
  select d.id into v_drawn_film_id from public.drawn_films d
  where d.nomination_id=p_nomination_id for update;
  if v_drawn_film_id is not null then
    delete from public.seen_votes where drawn_film_id=v_drawn_film_id;
    delete from public.movie_ratings where drawn_film_id=v_drawn_film_id;
    delete from public.drawn_film_metadata where drawn_film_id=v_drawn_film_id;
    update public.drawn_films set title=v_title,status='checking',vote_count=0,seen_count=0,
      rating_count=0,decided_at=null where id=v_drawn_film_id;
  end if;
end;
$$;

create or replace function public.admin_draw_next(p_night_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_nomination record;
  v_film_id uuid := gen_random_uuid();
  v_member_count integer;
  v_eligible_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_status text;
  v_decided_at timestamptz;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select phase into v_phase from public.movie_nights where id=p_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'La fase nomination è terminata.'; end if;
  if exists(select 1 from public.night_members where night_id=p_night_id and not has_nominated) then
    raise exception 'Attendi che tutti inviino una nomination.';
  end if;
  if exists(select 1 from public.movie_nominations n
    where n.night_id=p_night_id and n.status='queued'
      and (select count(*) filter(where nsv.has_seen)
        from public.nomination_seen_votes nsv
        join public.night_members nm on nm.night_id=p_night_id and nm.user_id=nsv.user_id
        where nsv.nomination_id=n.id and nm.user_id is distinct from n.user_id)*100
        > (select count(*) from public.night_members nm
          where nm.night_id=p_night_id and nm.user_id is distinct from n.user_id)*55) then
    raise exception 'Chi ha proposto una nomination già vista deve sostituirla prima del sorteggio.';
  end if;
  if exists(select 1 from public.drawn_films where night_id=p_night_id and status='rejected') then
    raise exception 'Il responsabile della nomination deve sostituire il titolo rifiutato.';
  end if;
  select n.id,n.title,n.category_id,n.user_id into v_nomination
  from public.movie_nominations n where n.night_id=p_night_id and n.status='queued'
  order by random() limit 1 for update skip locked;
  if v_nomination.id is null then raise exception 'Il pool delle nomination è vuoto.'; end if;
  select count(*)::integer into v_member_count from public.night_members nm where nm.night_id=p_night_id;
  select count(*)::integer into v_eligible_count from public.night_members nm
  where nm.night_id=p_night_id and nm.user_id is distinct from v_nomination.user_id;
  select count(*)::integer,count(*) filter(where nsv.has_seen)::integer
    into v_vote_count,v_seen_count
  from public.nomination_seen_votes nsv
  join public.night_members nm on nm.night_id=p_night_id and nm.user_id=nsv.user_id
  where nsv.nomination_id=v_nomination.id and nm.user_id is distinct from v_nomination.user_id;
  if v_vote_count=v_eligible_count then
    v_status := case when v_seen_count*100>v_eligible_count*55 then 'rejected' else 'approved' end;
    v_decided_at := now();
  else
    v_status := 'checking';
    v_decided_at := null;
  end if;
  update public.movie_nominations set status='drawn' where id=v_nomination.id;
  insert into public.drawn_films(
    id,night_id,nomination_id,title,category_id,status,member_count,vote_count,seen_count,decided_at
  ) values (
    v_film_id,p_night_id,v_nomination.id,v_nomination.title,v_nomination.category_id,
    v_status,v_member_count,v_vote_count,v_seen_count,v_decided_at
  );
  insert into public.seen_votes(drawn_film_id,user_id,has_seen,voted_at)
  select v_film_id,nsv.user_id,nsv.has_seen,nsv.voted_at
  from public.nomination_seen_votes nsv
  join public.night_members nm on nm.night_id=p_night_id and nm.user_id=nsv.user_id
  where nsv.nomination_id=v_nomination.id and nm.user_id is distinct from v_nomination.user_id
  on conflict(drawn_film_id,user_id) do update set has_seen=excluded.has_seen,voted_at=excluded.voted_at;
  return v_film_id;
end;
$$;

create or replace function public.get_nomination_vote_details(p_nomination_id uuid)
returns table(
  username text,has_seen boolean,seen_voted_at timestamptz,rating numeric,rated_at timestamptz
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_phase text;
  v_owner_id uuid;
begin
  if auth.uid() is null then raise exception 'Accedi per visualizzare i voti.'; end if;
  select n.night_id,n.user_id,mn.phase into v_night_id,v_owner_id,v_phase
  from public.movie_nominations n join public.movie_nights mn on mn.id=n.night_id
  where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_phase is distinct from 'complete' then
    raise exception 'I voti individuali saranno visibili dopo la pubblicazione della classifica.';
  end if;
  return query
    select p.username,nsv.has_seen,nsv.voted_at,mr.rating,mr.rated_at
    from public.night_members nm
    join public.profiles p on p.id=nm.user_id
    left join public.nomination_seen_votes nsv
      on nsv.nomination_id=p_nomination_id and nsv.user_id=nm.user_id
    left join public.drawn_films d on d.nomination_id=p_nomination_id
    left join public.movie_ratings mr on mr.drawn_film_id=d.id and mr.user_id=nm.user_id
    where nm.night_id=v_night_id and nm.user_id is distinct from v_owner_id
    order by lower(p.username),p.username;
end;
$$;

-- Keep deletion cleanup compatible with the submitter-excluded vote count.
create or replace function public.cleanup_deleted_profile_activity()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  v_night_ids uuid[];
begin
  select array_agg(affected.night_id) into v_night_ids from (
    select nm.night_id from public.night_members nm where nm.user_id=old.id
    union select np.night_id from public.night_participants np where np.user_id=old.id
    union select n.night_id from public.movie_nominations n where n.user_id=old.id
    union select d.night_id from public.drawn_films d join public.seen_votes sv on sv.drawn_film_id=d.id where sv.user_id=old.id
    union select d.night_id from public.drawn_films d join public.movie_ratings r on r.drawn_film_id=d.id where r.user_id=old.id
    union select n.night_id from public.movie_nominations n join public.nomination_seen_votes nsv on nsv.nomination_id=n.id where nsv.user_id=old.id
    union select mn.id from public.movie_nights mn where mn.created_by=old.id
  ) affected;
  perform mn.id from public.movie_nights mn where mn.id=any(v_night_ids) order by mn.id for update;
  update public.movie_nights set created_by=null where created_by=old.id;
  delete from public.seen_votes where user_id=old.id;
  delete from public.nomination_seen_votes where user_id=old.id;
  delete from public.movie_ratings where user_id=old.id;
  delete from public.movie_nominations where user_id=old.id;
  delete from public.night_participants where user_id=old.id;
  delete from public.night_members where user_id=old.id;

  if v_night_ids is not null then
    delete from public.movie_nights mn where mn.id=any(v_night_ids)
      and not exists(select 1 from public.night_members nm where nm.night_id=mn.id);
    with offsets as (
      select night_id,max(pick_position)+count(*)::integer+1 as shift
      from public.night_members where night_id=any(v_night_ids) group by night_id
    )
    update public.night_members nm set pick_position=nm.pick_position+offsets.shift
    from offsets where offsets.night_id=nm.night_id;
    with ranked as (
      select nm.night_id,nm.user_id,row_number() over(partition by nm.night_id order by nm.pick_position,nm.user_id)::integer as new_position
      from public.night_members nm where nm.night_id=any(v_night_ids)
    )
    update public.night_members nm set pick_position=ranked.new_position
    from ranked where ranked.night_id=nm.night_id and ranked.user_id=nm.user_id;

    with vote_totals as (
      select d.id,
        count(nm.user_id) filter(where nm.user_id is distinct from n.user_id)::integer as eligible_count,
        count(sv.user_id) filter(where nm.user_id is distinct from n.user_id)::integer as vote_count,
        count(sv.user_id) filter(where nm.user_id is distinct from n.user_id and sv.has_seen)::integer as seen_count
      from public.drawn_films d
      join public.movie_nominations n on n.id=d.nomination_id
      join public.night_members nm on nm.night_id=d.night_id
      left join public.seen_votes sv on sv.drawn_film_id=d.id and sv.user_id=nm.user_id
      where d.night_id=any(v_night_ids)
      group by d.id,n.user_id
    )
    update public.drawn_films d set
      member_count=(select count(*)::integer from public.night_members nm where nm.night_id=d.night_id),
      vote_count=vt.vote_count,seen_count=vt.seen_count,
      status=case when vt.vote_count=vt.eligible_count
        then case when vt.seen_count*100>vt.eligible_count*55 then 'rejected' else 'approved' end
        else 'checking' end,
      decided_at=case when vt.vote_count=vt.eligible_count then coalesce(d.decided_at,now()) else null end
    from vote_totals vt where vt.id=d.id;

    delete from public.movie_ratings r using public.drawn_films d
    where r.drawn_film_id=d.id and d.night_id=any(v_night_ids) and d.status='rejected';
    update public.drawn_films d set rating_count=(
      select count(*)::integer from public.movie_ratings r
      join public.movie_nominations n on n.id=d.nomination_id
      where r.drawn_film_id=d.id and r.user_id is distinct from n.user_id
    ) where d.night_id=any(v_night_ids);
    update public.movie_nights mn set phase='nominations'
    where mn.id=any(v_night_ids) and mn.phase='category_draft'
      and exists(select 1 from public.night_members nm where nm.night_id=mn.id)
      and not exists(select 1 from public.night_participants np where np.night_id=mn.id and np.category_id is null);
    update public.movie_nights mn set revealed_count=least(mn.revealed_count,(
      select count(*)::integer from public.drawn_films d where d.night_id=mn.id and d.status='approved'
    )) where mn.id=any(v_night_ids);
  end if;
  return old;
end;
$$;

revoke all on function public.get_night_nomination_list(uuid) from public,anon,authenticated;
revoke all on function public.submit_nomination_seen_vote(uuid,boolean) from public,anon,authenticated;
revoke all on function public.replace_nomination_after_seen_vote(uuid,text,text) from public,anon,authenticated;
revoke all on function public.cleanup_deleted_profile_activity() from public,anon,authenticated;
grant execute on function public.get_night_nomination_list(uuid) to authenticated;
grant execute on function public.submit_nomination_seen_vote(uuid,boolean) to authenticated;
grant execute on function public.replace_nomination_after_seen_vote(uuid,text,text) to authenticated;
