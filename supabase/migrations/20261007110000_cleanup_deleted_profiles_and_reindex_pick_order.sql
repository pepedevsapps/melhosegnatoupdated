-- Deleting a profile removes its game activity, while keeping shared nights
-- that still have participants. Compact saved pick positions so the score
-- bonus remains distributed across the users who are still in each night.

alter table public.movie_nights
  alter column created_by drop not null;
alter table public.movie_nights
  drop constraint if exists movie_nights_created_by_fkey;
alter table public.movie_nights
  add constraint movie_nights_created_by_fkey
  foreign key (created_by) references public.profiles(id) on delete set null;

alter table public.drawn_films
  drop constraint if exists drawn_films_nomination_id_fkey;
alter table public.drawn_films
  add constraint drawn_films_nomination_id_fkey
  foreign key (nomination_id) references public.movie_nominations(id) on delete cascade;

create or replace function public.cleanup_deleted_profile_activity()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_night_ids uuid[];
begin
  select array_agg(affected.night_id) into v_night_ids
  from (
    select nm.night_id from public.night_members nm where nm.user_id=old.id
    union
    select np.night_id from public.night_participants np where np.user_id=old.id
    union
    select n.night_id from public.movie_nominations n where n.user_id=old.id
    union
    select d.night_id from public.drawn_films d
      join public.seen_votes sv on sv.drawn_film_id=d.id where sv.user_id=old.id
    union
    select d.night_id from public.drawn_films d
      join public.movie_ratings r on r.drawn_film_id=d.id where r.user_id=old.id
    union
    select n.night_id from public.movie_nominations n
      join public.nomination_seen_votes nsv on nsv.nomination_id=n.id where nsv.user_id=old.id
    union
    select mn.id from public.movie_nights mn where mn.created_by=old.id
  ) affected;

  -- Serialize cleanup with game actions that take a night lock before writing.
  perform mn.id from public.movie_nights mn
  where mn.id=any(v_night_ids) order by mn.id for update;

  -- Remove the creator reference without deleting a shared night.
  update public.movie_nights set created_by=null where created_by=old.id;

  -- Remove every user-owned vote and rating. The profile foreign keys also
  -- cascade, but doing this here lets us repair the cached game totals.
  delete from public.seen_votes where user_id=old.id;
  delete from public.nomination_seen_votes where user_id=old.id;
  delete from public.movie_ratings where user_id=old.id;

  -- A drawn film belongs to its nomination. Cascading this foreign key removes
  -- the film, its OMDb metadata, seen votes, and ratings together.
  delete from public.movie_nominations where user_id=old.id;
  delete from public.night_participants where user_id=old.id;
  delete from public.night_members where user_id=old.id;

  if v_night_ids is not null then
    -- Empty nights cannot be played and would otherwise prevent starting the
    -- next one. Keep any night that still has at least one participant.
    delete from public.movie_nights mn
    where mn.id=any(v_night_ids)
      and not exists(select 1 from public.night_members nm where nm.night_id=mn.id);

    -- Move positions above the current range first to avoid collisions with
    -- the unique (night_id,pick_position) index during compaction.
    with offsets as (
      select night_id,max(pick_position)+count(*)::integer+1 as shift
      from public.night_members where night_id=any(v_night_ids) group by night_id
    )
    update public.night_members nm set pick_position=nm.pick_position+offsets.shift
    from offsets where offsets.night_id=nm.night_id;

    with ranked as (
      select nm.night_id,nm.user_id,
        row_number() over(partition by nm.night_id order by nm.pick_position,nm.user_id)::integer as new_position
      from public.night_members nm
      where nm.night_id=any(v_night_ids)
    )
    update public.night_members nm set pick_position=ranked.new_position
    from ranked where ranked.night_id=nm.night_id and ranked.user_id=nm.user_id;

    -- Recalculate draw progress and the seen-vote decision using the smaller
    -- member count. If a film is no longer approved, its ratings no longer
    -- contribute to scoring.
    with vote_totals as (
      select d.id,count(sv.user_id)::integer as vote_count,
        count(*) filter(where sv.has_seen)::integer as seen_count
      from public.drawn_films d
      join public.night_members nm on nm.night_id=d.night_id
      left join public.seen_votes sv on sv.drawn_film_id=d.id
      where d.night_id=any(v_night_ids)
      group by d.id
    )
    update public.drawn_films d set
      member_count=(select count(*)::integer from public.night_members nm where nm.night_id=d.night_id),
      vote_count=vt.vote_count,
      seen_count=vt.seen_count,
      status=case
        when vt.vote_count=(select count(*) from public.night_members nm where nm.night_id=d.night_id)
          then case when vt.seen_count*100 >
            (select count(*) from public.night_members nm where nm.night_id=d.night_id)*55
            then 'rejected' else 'approved' end
        else 'checking'
      end,
      decided_at=case
        when vt.vote_count=(select count(*) from public.night_members nm where nm.night_id=d.night_id)
          then coalesce(d.decided_at,now())
        else null
      end
    from vote_totals vt where vt.id=d.id;

    delete from public.movie_ratings r using public.drawn_films d
    where r.drawn_film_id=d.id and d.night_id=any(v_night_ids) and d.status='rejected';
    update public.drawn_films d set rating_count=(
      select count(*) from public.movie_ratings r where r.drawn_film_id=d.id
    ) where d.night_id=any(v_night_ids);

    -- A removed participant may have been the final unpicked category turn.
    update public.movie_nights mn set phase='nominations'
    where mn.id=any(v_night_ids) and mn.phase='category_draft'
      and exists(select 1 from public.night_members nm where nm.night_id=mn.id)
      and not exists(select 1 from public.night_participants np
        where np.night_id=mn.id and np.category_id is null);

    -- Keep the legacy reveal counter within the surviving approved film count.
    update public.movie_nights mn set revealed_count=least(mn.revealed_count,(
      select count(*)::integer from public.drawn_films d
      where d.night_id=mn.id and d.status='approved'
    )) where mn.id=any(v_night_ids);
  end if;

  return old;
end;
$$;

drop trigger if exists cleanup_deleted_profile_activity_before_delete on public.profiles;
create trigger cleanup_deleted_profile_activity_before_delete
before delete on public.profiles
for each row execute procedure public.cleanup_deleted_profile_activity();

revoke all on function public.cleanup_deleted_profile_activity() from public,anon,authenticated;

-- Remove empty nights left by earlier account deletions, then repair pick gaps
-- in existing nights. The offset avoids collisions with the unique index.
delete from public.movie_nights mn
where not exists(select 1 from public.night_members nm where nm.night_id=mn.id);
with offsets as (
  select night_id,max(pick_position)+count(*)::integer+1 as shift
  from public.night_members group by night_id
)
update public.night_members nm set pick_position=nm.pick_position+offsets.shift
from offsets where offsets.night_id=nm.night_id;
with ranked as (
  select night_id,user_id,
    row_number() over(partition by night_id order by pick_position,user_id)::integer as new_position
  from public.night_members
)
update public.night_members nm set pick_position=ranked.new_position
from ranked where ranked.night_id=nm.night_id and ranked.user_id=nm.user_id;

-- Recompute participant-sensitive draw totals from the remaining night members.
update public.drawn_films d set
  member_count=totals.member_count,
  vote_count=totals.vote_count,
  seen_count=totals.seen_count,
  rating_count=totals.rating_count,
  status=case
    when totals.vote_count=totals.member_count
      then case when totals.seen_count*100 > totals.member_count*55 then 'rejected' else 'approved' end
    else 'checking'
  end,
  decided_at=case when totals.vote_count=totals.member_count then coalesce(d.decided_at,now()) else null end
from (
  select d0.id,
    (select count(*)::integer from public.night_members nm where nm.night_id=d0.night_id) as member_count,
    (select count(*)::integer from public.seen_votes sv where sv.drawn_film_id=d0.id) as vote_count,
    (select count(*)::integer from public.seen_votes sv where sv.drawn_film_id=d0.id and sv.has_seen) as seen_count,
    (select count(*)::integer from public.movie_ratings r where r.drawn_film_id=d0.id) as rating_count
  from public.drawn_films d0
) totals where totals.id=d.id and totals.member_count>0;

delete from public.movie_ratings r using public.drawn_films d
where r.drawn_film_id=d.id and d.status='rejected';
update public.drawn_films d set rating_count=(
  select count(*) from public.movie_ratings r where r.drawn_film_id=d.id
);

update public.movie_nights mn set revealed_count=least(mn.revealed_count,(
  select count(*)::integer from public.drawn_films d
  where d.night_id=mn.id and d.status='approved'
));
