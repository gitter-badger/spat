------------------------------------------------------------------------------
--  Copyright (C) 2020 by Heisenbug Ltd. (gh+spat@heisenbug.eu)
--
--  This work is free. You can redistribute it and/or modify it under the
--  terms of the Do What The Fuck You Want To Public License, Version 2,
--  as published by Sam Hocevar. See the LICENSE file for more details.
------------------------------------------------------------------------------
pragma License (Unrestricted);

with SPAT.Log;
with SPAT.Proof_Attempt;
with SPAT.Proof_Item;

package body SPAT.Spark_Info.Heuristics is

   Null_Times : constant Times :=
     Times'(Success     => 0.0,
            Failed      => 0.0,
            Max_Success => 0.0,
            Max_Steps   => 0);

   ---------------------------------------------------------------------------
   --  Min_Failed_Time
   --
   --  Comparison operator for a proof attempts.
   --
   --  If we have a total failed time, this takes precedence, as this may mean
   --  that the prover fails a lot.
   --
   --  If none of the provers have a failed time (i.e. = 0.0) that means, they
   --  all succeeded whenever they were being called.
   --
   --  Assuming that the one being called more ofte is also the most successful
   --  one in general, we sort by highest success time.
   --
   --  NOTE: This is all guesswork and despite the subrouting being called
   --        "Find_Optimum", this is definitely far from optimal.  For an
   --        optimal result, we would need the data for all provers which
   --        defeats the whole purpose.
   ---------------------------------------------------------------------------
   function Min_Failed_Time (Left  : in Prover_Data;
                             Right : in Prover_Data) return Boolean;

   ---------------------------------------------------------------------------
   --  By_Name
   --
   --  Comparison operator for file list.
   ---------------------------------------------------------------------------
   function By_Name (Left  : in File_Data;
                     Right : in File_Data) return Boolean is
      (Left.Name < Right.Name);

   package File_Sorting is new
     File_Vectors.Generic_Sorting ("<" => By_Name);

   package Prover_Sorting is new
     Prover_Vectors.Generic_Sorting ("<" => Min_Failed_Time);

   package Prover_Maps is new
     Ada.Containers.Hashed_Maps (Key_Type        => Subject_Name,
                                 Element_Type    => Times,
                                 Hash            => SPAT.Hash,
                                 Equivalent_Keys => "=",
                                 "="             => "=");

   package Per_File is new
     Ada.Containers.Hashed_Maps (Key_Type        => SPAT.Source_File_Name,
                                 Element_Type    => Prover_Maps.Map,
                                 Hash            => SPAT.Hash,
                                 Equivalent_Keys => SPAT."=",
                                 "="             => Prover_Maps."=");

   ---------------------------------------------------------------------------
   --  Find_Optimum
   --
   --  NOTE: As of now, this implementation is also highly inefficient.
   --
   --        It uses a lot of lookups where a proper data structure would have
   --        been able to prevent that.
   --        I just found it more important to get a working prototype, than a
   --        blazingly fast one which doesn't.
   ---------------------------------------------------------------------------
   function Find_Optimum (Info : in T) return File_Vectors.Vector
   is
      --  FIXME: This should probably go into the README.md instead of here.
      --
      --  For starters, trying to optimize proof times is relatively simple.
      --  For that you just need to collect all proofs which failed on one
      --  prover, but were successful with the other.  Of course, once you
      --  change the configuration, the picture may be different.
      --
      --  The problematic part is that at no point we have the full
      --  information (i.e. some provers might have been faster than others,
      --  but they were never tried, because slower ones still proved the VC).
      --
      --  Example:
      --
      --  RFLX.RFLX_Types.U64_Insert => 120.0 s/1.6 ks
      --  `-VC_PRECONDITION rflx-rflx_generic_types.adb:221:39 => 120.0 s/491.0 s
      --   `-CVC4: 120.0 s (Timeout)
      --    -Z3: 120.0 s (Timeout)
      --    -altergo: 188.2 ms (Valid)
      --   `-Z3: 120.0 s (Timeout)
      --    -CVC4: 5.4 s (Valid)
      --   `-Z3: 120.0 s (Timeout)
      --    -CVC4: 5.3 s (Valid)
      --   `-Z3: 60.0 ms (Valid)
      --   `-Z3: 40.0 ms (Valid)
      --   `-Z3: 20.0 ms (Valid)
      --   `-Trivial: 0.0 s (Valid)
      --
      --  Here we have 7 proof paths in total, let's ignore the ones that have
      --  only one prover (for these we can't say anything), leaving us with
      --
      --  RFLX.RFLX_Types.U64_Insert => 120.0 s/1.6 ks
      --  `-VC_PRECONDITION rflx-rflx_generic_types.adb:221:39 => 120.0 s/491.0 s
      --   `-CVC4: 120.0 s (Timeout)
      --    -Z3: 120.0 s (Timeout)
      --    -altergo: 188.2 ms (Valid)
      --   `-Z3: 120.0 s (Timeout)
      --    -CVC4: 5.4 s (Valid)
      --   `-Z3: 120.0 s (Timeout)
      --    -CVC4: 5.3 s (Valid)
      --
      --  We see, that altergo could proof the first path quite fast, so
      --  chances are it might be able to proof the remaining paths similarly
      --  fast. But without trying, there's no way of knowing it, so stick to
      --  the information we have.
      --
      --  Path  Prover       Max_Success Max_Failed Saving
      --  1     "altergo"    188.2 ms    --         119.8 s
      --        "Z3"           0.0 s     120.0 s    --
      --        "CVC4"         0.0 s     120.0 s    --
      --  2     "altergo"      --        --         --
      --        "Z3"           --        120.0 s    --
      --        "CVC4"         5.4 s     --         114.6
      --  3     "altergo"      --        --         --
      --        "Z3"           --        120.0 s    --
      --        "CVC4"         5.3 s     --         114.7
      --
      --  We take different orders into account (maybe we can even read them
      --  from the project file?).
      --
      --  "altergo", "CVC4",    "Z3"  : *maybe* -119.8 s
      --  "CVC4",    "altergo", "Z3"  : *maybe* -114.6 s
      --  "altergo", "Z3",      "CVC4": *maybe* -119.8 s

      --  We need to split the proofs per file, as this is the minimum
      --  granularity we can specify for the order of provers.
      --  TODO: Handle spec/body/separates correctly.

      Source_List : Per_File.Map;
      use type Per_File.Cursor;

      Times_Position : Per_File.Cursor;
      Dummy_Inserted : Boolean;
   begin
      --  Collect all proof items in the Per_File/Proof_Records structure.
      for E of Info.Entities loop
         for Proof in E.The_Tree.Iterate_Children (Parent => E.Proofs) loop
            declare
               --  Extract our proof component from the tree.
               The_Proof : constant Proof_Item.T'Class :=
                 Proof_Item.T'Class (Entity.Tree.Element (Position => Proof));
            begin
               if
                 Source_List.Find
                   (Key => The_Proof.Source_File) = Per_File.No_Element
               then
                  Source_List.Insert
                    (Key      => The_Proof.Source_File,
                     New_Item => Prover_Maps.Empty_Map,
                     Position => Times_Position,
                        Inserted => Dummy_Inserted);
               end if;

               --  Iterate over all the verification conditions within the
               --  proof.
               for VC in
                 E.The_Tree.Iterate_Children
                   (Parent => Entity.Tree.First_Child (Position => Proof))
               loop
                  declare
                     --  Extract our VC component from the tree.
                     The_Attempt : constant Proof_Attempt.T'Class :=
                       Proof_Attempt.T'Class
                         (Entity.Tree.Element (Position => VC));
                     use type Proof_Attempt.Prover_Result;
                  begin
                     declare
                        File_Ref : constant Per_File.Reference_Type :=
                          Source_List.Reference
                            (Position => Times_Position);
                        Prover_Cursor :  Prover_Maps.Cursor :=
                          File_Ref.Element.Find (The_Attempt.Prover);
                        use type Prover_Maps.Cursor;
                     begin
                        if Prover_Cursor = Prover_Maps.No_Element then
                           --  New prover name, insert it.
                           File_Ref.Element.Insert
                             (Key      => The_Attempt.Prover,
                              New_Item => Null_Times,
                              Position => Prover_Cursor,
                              Inserted => Dummy_Inserted);
                        end if;

                        declare
                           Prover_Element : constant Prover_Maps.Reference_Type :=
                             File_Ref.Reference (Position => Prover_Cursor);
                        begin
                           if The_Attempt.Result = Proof_Attempt.Valid then
                              Prover_Element.Success :=
                                Prover_Element.Success + The_Attempt.Time;

                              Prover_Element.Max_Success :=
                                Duration'Max (Prover_Element.Max_Success,
                                              The_Attempt.Time);

                              Prover_Element.Max_Steps :=
                                Prover_Steps'Max (Prover_Element.Max_Steps,
                                                  The_Attempt.Steps);
                           else
                              Prover_Element.Failed :=
                                Prover_Element.Failed + The_Attempt.Time;
                           end if;
                        end;
                     end;
                  end;
               end loop;
            end;
         end loop;
      end loop;

      --  Debug output result.
      if Log.Debug_Enabled then
         for C in Source_List.Iterate loop
            Log.Debug (Message => To_String (Per_File.Key (Position => C)));

            for Prover in Per_File.Element (Position => C).Iterate loop
               declare
                  E : constant Times :=
                    Prover_Maps.Element (Position => Prover);
               begin
                  Log.Debug
                    (Message =>
                       "  " &
                       To_String (Prover_Maps.Key (Position => Prover)));
                  Log.Debug (Message => "    t(Success) " & SPAT.Image (E.Success));
                  Log.Debug (Message => "    t(Failed)  " & SPAT.Image (E.Failed));
                  Log.Debug (Message => "    T(Success) " & SPAT.Image (E.Max_Success));
                  Log.Debug (Message => "    S(Success)" & E.Max_Steps'Image);
               end;
            end loop;
         end loop;
      end if;

      --  Build the result vector.
      declare
         Result : File_Vectors.Vector;
      begin
         for Source_Cursor in Source_List.Iterate loop
            declare
               Prover_Vector : Prover_Vectors.Vector;
            begin
               for Prover_Cursor in Source_List (Source_Cursor).Iterate loop
                  --  Special handling for the "Trivial" prover. We never want
                  --  to show this one.
                  if
                    Prover_Maps.Key (Position => Prover_Cursor) /=
                    To_Name ("Trivial")
                  then
                     Prover_Vector.Append
                       (New_Item =>
                          Prover_Data'
                            (Name =>
                               Prover_Maps.Key (Position => Prover_Cursor),
                             Time =>
                               Prover_Maps.Element
                                 (Position => Prover_Cursor)));
                  end if;
               end loop;

               if not Prover_Vector.Is_Empty then
                  --  Sort provers by minimum failed time.
                  Prover_Sorting.Sort (Container => Prover_Vector);
                  Result.Append
                    (New_Item =>
                       File_Data'(Name    =>
                                    Per_File.Key (Position => Source_Cursor),
                                  Provers => Prover_Vector));
               end if;
            end;
         end loop;

         File_Sorting.Sort (Container => Result);

         return Result;
      end;
   end Find_Optimum;

   ---------------------------------------------------------------------------
   --  Min_Failed_Time
   ---------------------------------------------------------------------------
   function Min_Failed_Time (Left  : in Prover_Data;
                             Right : in Prover_Data) return Boolean is
   begin
      if Left.Time.Failed = Right.Time.Failed then
         --  Failed time is equal (likely zero, so prefer the prover with the
         --  *higher* success time.  This can be wrong, because this value
         --  mostly depends on which prover is called first.
         return Left.Time.Success > Right.Time.Success;
      end if;

      --  Prefer the prover that spends less wasted time.
      return Left.Time.Failed < Right.Time.Failed;
   end Min_Failed_Time;

end SPAT.Spark_Info.Heuristics;
