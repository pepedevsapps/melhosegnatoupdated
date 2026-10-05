alter table public.profiles
  add column if not exists onboarding_completed boolean not null default false;

create or replace function public.complete_onboarding()
returns void language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'Accedi per completare il tutorial.'; end if;
  update public.profiles set onboarding_completed=true where id=auth.uid();
  if not found then raise exception 'Profilo non trovato.'; end if;
end;
$$;

revoke all on function public.complete_onboarding() from public,anon,authenticated;
grant execute on function public.complete_onboarding() to authenticated;
