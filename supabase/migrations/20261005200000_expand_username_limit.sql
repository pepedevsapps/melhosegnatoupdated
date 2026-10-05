alter table public.profiles drop constraint if exists profiles_username_check;
alter table public.profiles drop constraint if exists profiles_username_format_check;
alter table public.profiles add constraint profiles_username_format_check
  check (username ~ '^[a-z0-9_]{3,50}$');

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  v_username text := lower(trim(coalesce(new.raw_user_meta_data->>'username','')));
  v_username_provided boolean := nullif(trim(coalesce(new.raw_user_meta_data->>'username','')),'') is not null;
  v_base_username text;
  v_suffix integer := 0;
  v_admin_email text;
  v_role text := 'player';
begin
  if not v_username_provided then
    v_base_username := lower(regexp_replace(split_part(coalesce(new.email,''),'@',1),'[^a-z0-9_]+','_','g'));
    v_base_username := trim(both '_' from v_base_username);
    if char_length(v_base_username)<3 then v_base_username := 'user'; end if;
    v_base_username := left(v_base_username,50);
    v_username := v_base_username;
    select email into v_admin_email from public.admin_bootstrap where singleton=true;
    while exists(select 1 from public.profiles where username=v_username)
       or (v_username='pepe1914' and (v_admin_email is null or lower(v_admin_email)<>lower(new.email))) loop
      v_suffix := v_suffix+1;
      v_username := left(v_base_username,49-char_length(v_suffix::text)) || '_' || v_suffix::text;
    end loop;
  end if;
  if v_username !~ '^[a-z0-9_]{3,50}$' then
    raise exception 'Username non valido. Usa 3-50 lettere, numeri o underscore.';
  end if;
  if v_username = 'pepe1914' then
    select email into v_admin_email from public.admin_bootstrap where singleton=true;
    if v_admin_email is null or lower(v_admin_email) <> lower(new.email) then
      raise exception 'Username riservato.';
    end if;
    v_role := 'admin';
  end if;
  insert into public.profiles(id,username,role) values(new.id,v_username,v_role);
  return new;
end;
$$;
