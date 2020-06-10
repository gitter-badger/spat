------------------------------------------------------------------------------
--  Copyright (C) 2020 by Heisenbug Ltd. (gh+spat@heisenbug.eu)
--
--  This work is free. You can redistribute it and/or modify it under the
--  terms of the Do What The Fuck You Want To Public License, Version 2,
--  as published by Sam Hocevar. See the LICENSE file for more details.
------------------------------------------------------------------------------
pragma License (Unrestricted);

with Ada.Containers.Vectors;
with SPAT.Proof_Attempt.List;

package body SPAT.Proof_Item is

   package Cursor_Lists is new
     Ada.Containers.Vectors (Index_Type   => Positive,
                             Element_Type => Entity.Tree.Cursor,
                             "="          => Entity.Tree."=");

   package Checks_Lists is new
     Ada.Containers.Vectors (Index_Type   => Positive,
                             Element_Type => Proof_Attempt.List.T,
                             "="          => Proof_Attempt.List."=");

   package Checks_By_Duration is new
     Checks_Lists.Generic_Sorting ("<" => Proof_Attempt.List."<");

   ---------------------------------------------------------------------------
   --  Add_To_Tree
   ---------------------------------------------------------------------------
   procedure Add_To_Tree (Object : in     JSON_Value;
                          Tree   : in out Entity.Tree.T;
                          Parent : in     Entity.Tree.Cursor)
   is
      Max_Time    : Duration := 0.0;
      Total_Time  : Duration := 0.0;
      Checks_List : Checks_Lists.Vector;
      Check_Tree  : constant JSON_Array :=
        Object.Get (Field => Field_Names.Check_Tree);
   begin
      --  Walk along the check_tree array to find all proof attempts and their
      --  respective times.
      for I in 1 .. GNATCOLL.JSON.Length (Arr => Check_Tree) loop
         declare
            Attempts : Proof_Attempt.List.T;
            Element  : constant JSON_Value   :=
                         GNATCOLL.JSON.Get (Arr   => Check_Tree,
                                            Index => I);
         begin
            if
              Preconditions.Ensure_Field (Object => Element,
                                          Field  => Field_Names.Proof_Attempts,
                                          Kind   => JSON_Object_Type)
            then
               declare
                  Attempt_List : constant JSON_Value
                    := Element.Get (Field => Field_Names.Proof_Attempts);

                  ------------------------------------------------------------
                  --  Create
                  ------------------------------------------------------------
                  procedure Mapping_CB (Name  : in UTF8_String;
                                        Value : in JSON_Value);

                  ------------------------------------------------------------
                  --  Create
                  ------------------------------------------------------------
                  procedure Mapping_CB (Name  : in UTF8_String;
                                        Value : in JSON_Value) is
                  begin
                     if
                       Proof_Attempt.Has_Required_Fields (Object => Value)
                     then
                        declare
                           Attempt : constant Proof_Attempt.T :=
                                       Proof_Attempt.Create
                                         (Prover => To_Name (Name),
                                          Object => Value);
                        begin
                           Attempts.Append (New_Item => Attempt);

                           Max_Time   := Duration'Max (Max_Time, Attempt.Time);
                           Total_Time := Total_Time + Attempt.Time;
                        end;
                     end if;
                  end Mapping_CB;
               begin
                  --  We use Map_JSON_Object here, because the prover name is
                  --  dynamic and potentially unknown to us, so we can't do a
                  --  lookup.
                  GNATCOLL.JSON.Map_JSON_Object (Val => Attempt_List,
                                                 CB  => Mapping_CB'Access);
               end;
            end if;

            --  Handle the "trivial_true" object (since GNAT_CE_2020.
            if
              Preconditions.Ensure_Field (Object => Element,
                                          Field  => Field_Names.Transformations,
                                          Kind   => JSON_Object_Type)
            then
               declare
                  Transformation : constant JSON_Value
                    := Element.Get (Field => Field_Names.Transformations);
               begin
                  if
                    Transformation.Has_Field (Field => Field_Names.Trivial_True)
                  then
                     Attempts.Append (New_Item => Proof_Attempt.Trivial_True);
                     --  No timing updates needed here, as we assume 0.0 for
                     --  trivially true proofs.
                  end if;
               end;
            end if;

            --  If not empty, add the current check tree to our list.
            if not Attempts.Is_Empty then
               Attempts.Sort_By_Duration;
               Checks_List.Append (New_Item => Attempts);
            end if;
         end;
      end loop;

      --  Sort checks list ascending by duration.
      Checks_By_Duration.Sort (Container => Checks_List);

      declare
         PI_Node : Entity.Tree.Cursor;
      begin
         --  Allocate node for our object.
         Tree.Insert_Child
           (Parent   => Parent,
            Before   => Entity.Tree.No_Element,
            New_Item => Proof_Item_Sentinel'(Entity.T with null record),
            Position => PI_Node);

         --  Now insert the whole object into the tree.
         declare
            PA_Node : Entity.Tree.Cursor;
         begin
            for Check of Checks_List loop
               Tree.Insert_Child (Parent   => PI_Node,
                                  Before   => Entity.Tree.No_Element,
                                  New_Item =>
                                    Checks_Sentinel'
                                      (Entity.T with
                                       Has_Failed_Attempts => True,
                                       Is_Unproved         => True),
                                  Position => PA_Node);

               for Attempt of Check loop
                  Tree.Insert_Child (Parent   => PA_Node,
                                     Before   => Entity.Tree.No_Element,
                                     New_Item => Attempt);
               end loop;

               --  Replace the Checks_Sentinel with proper data.
               Tree.Replace_Element
                 (Position => PA_Node,
                  New_Item =>
                    Checks_Sentinel'
                      (Entity.T with
                       Has_Failed_Attempts => Check.Has_Failed_Attempts,
                       Is_Unproved         => Check.Is_Unproved));
            end loop;
         end;

         --  And finally replace the sentinel node with the full object.
         Tree.Replace_Element
           (Position => PI_Node,
            New_Item =>
              T'(Entity_Location.Create (Object => Object) with
                 Suppressed            =>
                   (if Object.Has_Field (Field => Field_Names.Suppressed)
                    then Object.Get (Field => Field_Names.Suppressed)
                    else Null_Name), --  FIXME: Missing type check.
                 Rule                  => Object.Get (Field => Field_Names.Rule),
                 Severity              =>
                   Object.Get (Field => Field_Names.Severity),
                 Max_Time              => Max_Time,
                 Total_Time            => Total_Time,
                 Has_Failed_Attempts   => (for some Check of Checks_List =>
                                             Check.Has_Failed_Attempts),
                 Has_Unproved_Attempts => (for some Check of Checks_List =>
                                             Check.Is_Unproved)));
      end;
   end Add_To_Tree;

   ---------------------------------------------------------------------------
   --  Create
   ---------------------------------------------------------------------------
   overriding
   function Create (Object : in JSON_Value) return T is
     (raise Program_Error with
        "Create should not be called. Instead call Add_To_Tree.");

   ---------------------------------------------------------------------------
   --  Sort_By_Duration
   ---------------------------------------------------------------------------
   procedure Sort_By_Duration (This   : in out Entity.Tree.T;
                               Parent : in     Entity.Tree.Cursor) is
      The_List : Cursor_Lists.Vector;
      Num_Children : constant Ada.Containers.Count_Type :=
        Entity.Tree.Child_Count (Parent => Parent);
      use type Ada.Containers.Count_Type;
   begin
      if Num_Children < 2 then
         --  No elements to sort.
         return;
      end if;

      The_List.Reserve_Capacity (Capacity => Num_Children);

      --  Copy the tree's cursor into The_List.
      for C in This.Iterate_Children (Parent => Parent) loop
         The_List.Append (New_Item => C);
      end loop;

      --  Sort the list with our tree cursors.
      declare
         function Before (Left  : in Entity.Tree.Cursor;
                          Right : in Entity.Tree.Cursor) return Boolean is
           (Slower_Than
              (Left  => Proof_Item.T (Entity.Tree.Element (Position => Left)),
               Right => Proof_Item.T (Entity.Tree.Element (Position => Right))));

         package Sorting is new
           Cursor_Lists.Generic_Sorting ("<" => Before);
      begin
         Sorting.Sort (Container => The_List);
      end;

      --  Now rearrange the subtree according to our sorting order.
      for C of The_List loop
         This.Splice_Subtree (Parent   => Parent,
                              Before   => Entity.Tree.No_Element,
                              Position => C);
      end loop;
   end Sort_By_Duration;

end SPAT.Proof_Item;