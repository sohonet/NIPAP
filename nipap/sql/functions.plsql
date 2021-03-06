--
-- SQL functions for NIPAP
--

--
-- calc_indent is an internal function that calculates the correct indentation
-- for a prefix. It is called from a trigger function on the ip_net_plan table.
--
CREATE OR REPLACE FUNCTION calc_indent(arg_vrf integer, arg_prefix inet, delta integer) RETURNS bool AS $_$
DECLARE
	r record;
	current_indent integer;
BEGIN
	current_indent := (
		SELECT COUNT(*)
		FROM
			(SELECT DISTINCT inp.prefix
			FROM ip_net_plan inp
			WHERE vrf_id = arg_vrf
				AND iprange(prefix) >> iprange(arg_prefix::cidr)
			) AS a
		);

	UPDATE ip_net_plan SET indent = current_indent WHERE vrf_id = arg_vrf AND prefix = arg_prefix;
	UPDATE ip_net_plan SET indent = indent + delta WHERE vrf_id = arg_vrf AND iprange(prefix) << iprange(arg_prefix::cidr);

	RETURN true;
END;
$_$ LANGUAGE plpgsql;


--
-- Remove duplicate elements from an array
--
CREATE OR REPLACE FUNCTION array_undup(ANYARRAY) RETURNS ANYARRAY AS $_$
	SELECT ARRAY(
		SELECT DISTINCT $1[i]
		FROM generate_series(
			array_lower($1,1),
			array_upper($1,1)
			) AS i
		);
$_$ LANGUAGE SQL;


--
-- calc_tags is an internal function that calculates the inherited_tags
-- from parent prefixes to its children. It is called from a trigger function
-- on the ip_net_plan table.
--
CREATE OR REPLACE FUNCTION calc_tags(arg_vrf integer, arg_prefix inet) RETURNS bool AS $_$
DECLARE
	i_indent integer;
	new_inherited_tags text[];
BEGIN
	i_indent := (
		SELECT indent+1
		FROM ip_net_plan
		WHERE vrf_id = arg_vrf
			AND prefix = arg_prefix
		);
	-- set default if we don't have a parent prefix
	IF i_indent IS NULL THEN
		i_indent := 0;
	END IF;

	new_inherited_tags := (
		SELECT array_undup(array_cat(inherited_tags, tags))
		FROM ip_net_plan
		WHERE vrf_id = arg_vrf
			AND prefix = arg_prefix
		);
	-- set default if we don't have a parent prefix
	IF new_inherited_tags IS NULL THEN
		new_inherited_tags := '{}';
	END IF;

	UPDATE ip_net_plan SET inherited_tags = new_inherited_tags WHERE vrf_id = arg_vrf AND iprange(prefix ) << iprange(arg_prefix::cidr) AND indent = i_indent;

	RETURN true;
END;
$_$ LANGUAGE plpgsql;


--
-- find_free_prefix finds one or more prefix(es) of a certain prefix-length
-- inside a larger prefix. It is typically called by get_prefix or to return a
-- list of unused prefixes.
--

-- default to 1 prefix if no count is specified
CREATE OR REPLACE FUNCTION find_free_prefix(arg_vrf integer, IN arg_prefixes inet[], arg_wanted_prefix_len integer) RETURNS SETOF inet AS $_$
BEGIN
	RETURN QUERY SELECT * FROM find_free_prefix(arg_vrf, arg_prefixes, arg_wanted_prefix_len, 1) AS prefix;
END;
$_$ LANGUAGE plpgsql;

-- full function
CREATE OR REPLACE FUNCTION find_free_prefix(arg_vrf integer, IN arg_prefixes inet[], arg_wanted_prefix_len integer, arg_count integer) RETURNS SETOF inet AS $_$
DECLARE
	i_family integer;
	i_found integer;
	p int;
	search_prefix inet;
	current_prefix inet;
	max_prefix_len integer;
	covering_prefix inet;
BEGIN
	covering_prefix := NULL;
	-- sanity checking
	-- make sure all provided search_prefixes are of same family
	FOR p IN SELECT generate_subscripts(arg_prefixes, 1) LOOP
		IF i_family IS NULL THEN
			i_family := family(arg_prefixes[p]);
		END IF;

		IF i_family != family(arg_prefixes[p]) THEN
			RAISE EXCEPTION 'Search prefixes of inconsistent address-family provided';
		END IF;
	END LOOP;

	-- determine maximum prefix-length for our family
	IF i_family = 4 THEN
		max_prefix_len := 32;
	ELSE
		max_prefix_len := 128;
	END IF;

	-- the wanted prefix length cannot be more than 32 for ipv4 or more than 128 for ipv6
	IF arg_wanted_prefix_len > max_prefix_len THEN
		RAISE EXCEPTION 'Requested prefix-length exceeds max prefix-length %', max_prefix_len;
	END IF;
	--

	i_found := 0;

	-- loop through our search list of prefixes
	FOR p IN SELECT generate_subscripts(arg_prefixes, 1) LOOP
		-- save the current prefix in which we are looking for a candidate
		search_prefix := arg_prefixes[p];

		IF (masklen(search_prefix) > arg_wanted_prefix_len) THEN
			CONTINUE;
		END IF;

		SELECT set_masklen(search_prefix, arg_wanted_prefix_len) INTO current_prefix;

		-- we step through our search_prefix in steps of the wanted prefix
		-- length until we are beyond the broadcast size, ie end of our
		-- search_prefix
		WHILE set_masklen(current_prefix, masklen(search_prefix)) <= broadcast(search_prefix) LOOP
			-- tests put in order of speed, fastest one first

			-- the following are address family agnostic
			IF current_prefix IS NULL THEN
				SELECT broadcast(current_prefix) + 1 INTO current_prefix;
				CONTINUE;
			END IF;
			IF EXISTS (SELECT 1 FROM ip_net_plan WHERE vrf_id = arg_vrf AND prefix = current_prefix) THEN
				SELECT broadcast(current_prefix) + 1 INTO current_prefix;
				CONTINUE;
			END IF;

			-- avoid prefixes larger than the current_prefix but inside our search_prefix
			covering_prefix := (SELECT prefix FROM ip_net_plan WHERE vrf_id = arg_vrf AND iprange(prefix) >>= iprange(current_prefix::cidr) AND iprange(prefix) << iprange(search_prefix::cidr) ORDER BY masklen(prefix) ASC LIMIT 1);
			IF covering_prefix IS NOT NULL THEN
				SELECT set_masklen(broadcast(covering_prefix) + 1, arg_wanted_prefix_len) INTO current_prefix;
				CONTINUE;
			END IF;

			-- prefix must not contain any breakouts, that would mean it's not empty, ie not free
			IF EXISTS (SELECT 1 FROM ip_net_plan WHERE vrf_id = arg_vrf AND iprange(prefix) <<= iprange(current_prefix::cidr)) THEN
				SELECT broadcast(current_prefix) + 1 INTO current_prefix;
				CONTINUE;
			END IF;

			-- while the following two tests are family agnostic, they use
			-- functions and so are not indexed
			-- TODO: should they be indexed?

			IF ((i_family = 4 AND masklen(search_prefix) < 31) OR i_family = 6 AND masklen(search_prefix) < 127)THEN
				IF (set_masklen(network(search_prefix), max_prefix_len) = current_prefix) THEN
					SELECT broadcast(current_prefix) + 1 INTO current_prefix;
					CONTINUE;
				END IF;
				IF (set_masklen(broadcast(search_prefix), max_prefix_len) = current_prefix) THEN
					SELECT broadcast(current_prefix) + 1 INTO current_prefix;
					CONTINUE;
				END IF;
			END IF;

			RETURN NEXT current_prefix;

			i_found := i_found + 1;
			IF i_found >= arg_count THEN
				RETURN;
			END IF;

			current_prefix := broadcast(current_prefix) + 1;
		END LOOP;

	END LOOP;

	RETURN;

END;
$_$ LANGUAGE plpgsql;



--
-- get_prefix provides a convenient and MVCC-proof way of getting the next
-- available prefix from another prefix.
--
CREATE OR REPLACE FUNCTION get_prefix(arg_vrf integer, IN arg_prefixes inet[], arg_wanted_prefix_len integer) RETURNS inet AS $_$
DECLARE
	p inet;
BEGIN
	LOOP
		-- get a prefix
		SELECT prefix INTO p FROM find_free_prefix(arg_vrf, arg_prefixes, arg_wanted_prefix_len) AS prefix;

		BEGIN
			INSERT INTO ip_net_plan (vrf_id, prefix) VALUES (arg_vrf, p);
			RETURN p;
		EXCEPTION WHEN unique_violation THEN
			-- Loop and try to find a new prefix
		END;

	END LOOP;
END;
$_$ LANGUAGE plpgsql;



--
-- Helper to sort VRF RTs
--
-- RTs are tricky to sort since they exist in two formats and have the classic
-- sorted-as-string-problem;
--
--      199:456
--     1234:456
--  1.3.3.7:456
--
CREATE OR REPLACE FUNCTION vrf_rt_order(arg_rt text) RETURNS bigint AS $_$
DECLARE
	part_one text;
	part_two text;
	ip text;
BEGIN
	BEGIN
		part_one := split_part(arg_rt, ':', 1)::bigint;
	EXCEPTION WHEN others THEN
		ip := split_part(arg_rt, ':', 1);
		part_one := (split_part(ip, '.', 1)::bigint << 24) +
					(split_part(ip, '.', 2)::bigint << 16) +
					(split_part(ip, '.', 3)::bigint << 8) +
					(split_part(ip, '.', 4)::bigint);
	END;

	part_two := split_part(arg_rt, ':', 2);

	RETURN (part_one::bigint << 32) + part_two::bigint;
END;
$_$ LANGUAGE plpgsql IMMUTABLE STRICT;



--
-- Trigger function to validate VRF input, prominently the RT attribute which
-- needs to follow the allowed formats
--
CREATE OR REPLACE FUNCTION tf_ip_net_vrf_iu_before() RETURNS trigger AS $_$
DECLARE
	rt_part_one text;
	rt_part_two text;
	ip text;
BEGIN
	-- don't allow setting an RT for VRF id 0
	IF NEW.id = 0 THEN
		IF NEW.rt IS NOT NULL THEN
			RAISE EXCEPTION 'Invalid input for column rt, must be NULL for VRF id 0';
		END IF;
	ELSE -- make sure all VRF except for VRF id 0 has a proper RT
		-- make sure we only have two fields delimited by a colon
		IF (SELECT COUNT(1) FROM regexp_matches(NEW.rt, '(:)', 'g')) != 1 THEN
			RAISE EXCEPTION 'Invalid input for column rt, should be ASN:id (123:456) or IP:id (1.3.3.7:456)';
		END IF;

		-- check first part
		BEGIN
			-- either it's a integer (AS number)
			rt_part_one := split_part(NEW.rt, ':', 1)::bigint;
		EXCEPTION WHEN others THEN
			BEGIN
				-- or an IPv4 address
				ip := host(split_part(NEW.rt, ':', 1)::inet);
				rt_part_one := (split_part(ip, '.', 1)::bigint << 24) +
							(split_part(ip, '.', 2)::bigint << 16) +
							(split_part(ip, '.', 3)::bigint << 8) +
							(split_part(ip, '.', 4)::bigint);
			EXCEPTION WHEN others THEN
				RAISE EXCEPTION 'Invalid input for column rt, should be ASN:id (123:456) or IP:id (1.3.3.7:456)';
			END;
		END;

		-- check part two
		BEGIN
			rt_part_two := split_part(NEW.rt, ':', 2)::bigint;
		EXCEPTION WHEN others THEN
			RAISE EXCEPTION 'Invalid input for column rt, should be ASN:id (123:456) or IP:id (1.3.3.7:456)';
		END;
		NEW.rt := rt_part_one::text || ':' || rt_part_two::text;
	END IF;

	RETURN NEW;
END;
$_$ LANGUAGE plpgsql;


--
-- Trigger function to keep data consistent in the ip_net_vrf table with
-- regards to prefix type and similar. This function handles DELETE operations.
--
CREATE OR REPLACE FUNCTION tf_ip_net_vrf_d_before() RETURNS trigger AS $_$
BEGIN
	-- block delete of default VRF with id 0
	IF OLD.id = 0 THEN
		RAISE EXCEPTION '1200:Prohibited delete of default VRF (id=0).';
	END IF;

	RETURN OLD;
END;
$_$ LANGUAGE plpgsql;


--
-- Trigger function to keep data consistent in the ip_net_plan table with
-- regards to prefix type and similar. This function handles INSERTs and
-- UPDATEs.
--
CREATE OR REPLACE FUNCTION tf_ip_net_prefix_iu_before() RETURNS trigger AS $_$
DECLARE
	parent RECORD;
	child RECORD;
	i_max_pref_len integer;
BEGIN
	-- this is a shortcut to avoid running the rest of this trigger as it
	-- can be fairly costly performance wise
	--
	-- sanity checking is done on 'type' and derivations of 'prefix' so if
	-- those stay the same, we don't need to run the rest of the sanity
	-- checks.
	IF TG_OP = 'UPDATE' THEN
		-- don't allow changing VRF
		IF OLD.vrf_id != NEW.vrf_id THEN
			RAISE EXCEPTION '1200:Changing VRF is not allowed';
		END IF;
		-- if prefix, type and pool is the same, quick return!
		IF OLD.type = NEW.type AND OLD.prefix = NEW.prefix AND OLD.pool_id = NEW.pool_id THEN
			RETURN NEW;
		END IF;
	END IF;


	i_max_pref_len := 32;
	IF family(NEW.prefix) = 6 THEN
		i_max_pref_len := 128;
	END IF;
	-- contains the parent prefix
	SELECT * INTO parent FROM ip_net_plan WHERE vrf_id = NEW.vrf_id AND iprange(prefix) >> iprange(NEW.prefix) ORDER BY masklen(prefix) DESC LIMIT 1;

	-- check that type is correct on insert and update
	IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
		IF NEW.type = 'host' THEN
			IF masklen(NEW.prefix) != i_max_pref_len THEN
				RAISE EXCEPTION '1200:Prefix of type host must have all bits set in netmask';
			END IF;
			IF parent.prefix IS NULL THEN
				RAISE EXCEPTION '1200:Prefix of type host must have a parent (covering) prefix of type assignment';
			END IF;
			IF parent.type != 'assignment' THEN
				RAISE EXCEPTION '1200:Parent prefix (%) is of type % but must be of type ''assignment''', parent.prefix, parent.type;
			END IF;
			NEW.display_prefix := set_masklen(NEW.prefix::inet, masklen(parent.prefix));
		ELSIF NEW.type = 'assignment' THEN
			IF parent.type IS NULL THEN
				-- all good
			ELSIF parent.type != 'reservation' THEN
				RAISE EXCEPTION '1200:Parent prefix (%) is of type % but must be of type ''reservation''', parent.prefix, parent.type;
			END IF;

			-- also check that the new prefix does not have any childs other than hosts
			--
			-- need to separate INSERT and UPDATE as OLD (which we rely on in
			-- the update case) is not set for INSERT queries
			IF TG_OP = 'INSERT' THEN
				IF EXISTS (SELECT * FROM ip_net_plan WHERE vrf_id = NEW.vrf_id AND type != 'host' AND iprange(prefix) << iprange(NEW.prefix) LIMIT 1) THEN
					RAISE EXCEPTION '1200:Prefix of type ''assignment'' must not have any subnets other than of type ''host''';
				END IF;
			ELSIF TG_OP = 'UPDATE' THEN
				IF EXISTS (SELECT * FROM ip_net_plan WHERE vrf_id = NEW.vrf_id AND type != 'host' AND iprange(prefix) << iprange(NEW.prefix) AND prefix != OLD.prefix LIMIT 1) THEN
					RAISE EXCEPTION '1200:Prefix of type ''assignment'' must not have any subnets other than of type ''host''';
				END IF;
			END IF;
			NEW.display_prefix := NEW.prefix;
		ELSIF NEW.type = 'reservation' THEN
			IF parent.type IS NULL THEN
				-- all good
			ELSIF parent.type != 'reservation' THEN
				RAISE EXCEPTION '1200:Parent prefix (%) is of type % but must be of type ''reservation''', parent.prefix, parent.type;
			END IF;
			NEW.display_prefix := NEW.prefix;
		ELSE
			RAISE EXCEPTION '1200:Unknown prefix type';
		END IF;

		-- is the new prefix part of a pool?
		IF NEW.pool_id IS NOT NULL THEN
			-- if so, make sure all prefixes in that pool belong to the same VRF
			IF NEW.vrf_id != (SELECT vrf_id FROM ip_net_plan WHERE pool_id = NEW.pool_id LIMIT 1) THEN
				RAISE EXCEPTION '1200:Change not allowed. All member prefixes of a pool must be in a the same VRF.';
			END IF;
		END IF;

		-- Only allow setting node on prefixes of type host or typ assignment
		-- and when the prefix length is the maximum prefix length for the
		-- address family. The case for assignment is when a /32 is used as a
		-- loopback address or similar in which case it is registered as an
		-- assignment and should be able to have a node specified.
		IF NEW.node IS NOT NULL THEN
			IF NEW.type = 'host' THEN
				-- all good
			ELSIF NEW.type = 'reservation' THEN
				RAISE EXCEPTION '1200:Not allowed to set ''node'' value for prefixes of type ''reservation''.';
			ELSE
				-- not a /32 or /128, so do not allow
				IF masklen(NEW.prefix) != i_max_pref_len THEN
					RAISE EXCEPTION '1200:Not allowed to set ''node'' value for prefixes of type ''assignment'' which do not have all bits set in netmask.';
				END IF;
			END IF;
		END IF;
	END IF;

	-- only allow specific cases for changing the type of prefix
	IF TG_OP = 'UPDATE' THEN
		IF (OLD.type = 'reservation' AND NEW.type = 'assignment') OR (OLD.type = 'assignment' AND new.type = 'reservation') THEN
			-- don't allow any childs, since they would automatically be of the
			-- wrong type, ie inconsistent data
			IF EXISTS (SELECT 1 FROM ip_net_plan WHERE vrf_id = NEW.vrf_id AND iprange(prefix) << iprange(NEW.prefix)) THEN
				RAISE EXCEPTION '1200:Changing from type ''%'' to ''%'' requires there to be no child prefixes.', OLD.type, NEW.type;
			END IF;
		ELSE
			IF OLD.type != NEW.type THEN
				RAISE EXCEPTION '1200:Changing type is not allowed';
			END IF;
		END IF;
	END IF;

	-- Check country code- value needs to be a two letter country code
	-- according to ISO 3166-1 alpha-2
	--
	-- We do not check that the actual value is in ISO 3166-1, because that
	-- would entail including a full listing of country codes which we do not want
	-- as we risk including an outdated one. We don't want to force users to
	-- upgrade merely to get a new ISO 3166-1 list.
	IF TG_OP = 'INSERT' OR OLD.country != NEW.country THEN
		NEW.country = upper(NEW.country);
		IF NEW.country !~ '^[A-Z]{2}$' THEN
			RAISE EXCEPTION '1200: Please enter a two letter country code according to ISO 3166-1 alpha-2';
		END IF;
	END IF;

	-- all is well, return
	RETURN NEW;
END;
$_$ LANGUAGE plpgsql;


--
-- Trigger function to keep data consistent in the ip_net_plan table with
-- regards to prefix type and similar. This function handles DELETE operations.
--
CREATE OR REPLACE FUNCTION tf_ip_net_prefix_d_before() RETURNS trigger AS $_$
BEGIN
	-- prevent certain deletes to maintain DB integrity
	IF TG_OP = 'DELETE' THEN
		-- if an assignment contains hosts, we block the delete
		IF OLD.type = 'assignment' THEN
			-- contains one child prefix
			-- FIXME: optimize with this, what is improvement?
			-- IF (SELECT COUNT(1) FROM ip_net_plan WHERE prefix << OLD.prefix LIMIT 1) > 0 THEN
			IF (SELECT COUNT(1) FROM ip_net_plan WHERE prefix << OLD.prefix AND vrf_id = OLD.vrf_id) > 0 THEN
				RAISE EXCEPTION '1200:Prohibited delete, prefix (%) contains hosts.', OLD.prefix;
			END IF;
		END IF;
		-- everything else is allowed
	END IF;

	RETURN OLD;
END;
$_$ LANGUAGE plpgsql;


--
-- Trigger function to make update the indent level when adding or removing
-- prefixes.
--
CREATE OR REPLACE FUNCTION tf_ip_net_prefix_family_after() RETURNS trigger AS $$
DECLARE
	r RECORD;
	parent_prefix cidr;
BEGIN
	IF TG_OP = 'DELETE' THEN
		PERFORM calc_indent(OLD.vrf_id, OLD.prefix, -1);

		-- calc tags from parent of the deleted prefix to what is now the
		-- direct children of the parent prefix
		parent_prefix := (SELECT prefix FROM ip_net_plan WHERE vrf_id = OLD.vrf_id AND prefix >> OLD.prefix ORDER BY prefix DESC LIMIT 1);
		IF parent_prefix IS NULL THEN
			PERFORM calc_tags(OLD.vrf_id, OLD.prefix);
		ELSE
			PERFORM calc_tags(OLD.vrf_id, parent_prefix);
		END IF;
	ELSIF TG_OP = 'INSERT' THEN
		PERFORM calc_indent(NEW.vrf_id, NEW.prefix, 1);

		-- identify the parent and run calc_tags on it to inherit tags to
		-- the new prefix from the parent
		parent_prefix := (SELECT prefix FROM ip_net_plan WHERE vrf_id = NEW.vrf_id AND prefix >> NEW.prefix ORDER BY prefix DESC LIMIT 1);
		PERFORM calc_tags(NEW.vrf_id, parent_prefix);
		-- now push tags from the new prefix to its children
		PERFORM calc_tags(NEW.vrf_id, NEW.prefix);
	ELSIF TG_OP = 'UPDATE' THEN
		-- only act on changes to the prefix
		IF OLD.prefix != NEW.prefix THEN
			-- "restore" indent where the old prefix was
			PERFORM calc_indent(NEW.vrf_id, OLD.prefix, -1);
			-- and add indent where the new one is
			PERFORM calc_indent(NEW.vrf_id, NEW.prefix, 1);
		END IF;

		-- only act on changes to the tag columns
		IF OLD.tags != NEW.tags OR OLD.inherited_tags != NEW.inherited_tags THEN
			PERFORM calc_tags(NEW.vrf_id, NEW.prefix);
		END IF;
	ELSE
		-- nothing!
	END IF;
	RETURN NEW;
END;
$$ LANGUAGE plpgsql;
